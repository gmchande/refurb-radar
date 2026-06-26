# frozen_string_literal: true

require "json"
require "openssl"
require "time"
require "uri"

require_relative "refurb_radar/alerter"
require_relative "refurb_radar/fetcher"
require_relative "refurb_radar/buyability"
require_relative "refurb_radar/catalog"
require_relative "refurb_radar/config"
require_relative "refurb_radar/cloudflare_access"
require_relative "refurb_radar/control_store"
require_relative "refurb_radar/event_log"
require_relative "refurb_radar/matcher"
require_relative "refurb_radar/parser"
require_relative "refurb_radar/product_matrix"
require_relative "refurb_radar/state_store"
require_relative "refurb_radar/inventory_snapshot"
require_relative "refurb_radar/status_page"
require_relative "refurb_radar/targets_store"

module RefurbRadar
  DEFAULT_GRID_URL = "https://www.apple.com/ca/shop/refurbished/mac"
  DEFAULT_BUYABILITY_URL = "https://www.apple.com/ca/shop/buyability-message"
  DEFAULT_STATE_PATH = File.expand_path("../state/seen.json", __dir__)
  DEFAULT_CATALOG_PATH = File.expand_path("../state/catalog.json", __dir__)
  DEFAULT_EVENT_LOG_PATH = File.expand_path("../state/events.jsonl", __dir__)

  def self.env_value(env, key)
    env[key] || env[key.sub(/\AREFURB_RADAR_/, "APPLE_REFURB_")]
  end

  def self.env_fetch(env, key, default)
    value = env_value(env, key)
    value.nil? ? default : value
  end

  Candidate = Struct.new(
    :part_number,
    :title,
    :url,
    :model,
    :memory,
    :capacity,
    :price,
    :commit_string,
    :screen_size_inches,
    :chip_family,
    :alert_kind,
    keyword_init: true
  )

  Result = Struct.new(
    :checked_at,
    :total_tiles,
    :direct_watch_candidates,
    :target_tiles,
    :eligible_target_tiles,
    :confirmed_buyable,
    :availability_signals,
    :unconfirmed_candidates,
    :alerts,
    :warnings,
    :duration_seconds,
    keyword_init: true
  )

  class Error < StandardError; end
  class FetchError < Error; end
  class ParseError < Error; end

  class Check
    STALE_CATALOG_SECONDS = 24 * 60 * 60

    def initialize(
      grid_url: DEFAULT_GRID_URL,
      fetcher: Fetcher.new,
      parser: Parser.new,
      matcher: Matcher.new,
      buyability: Buyability.new,
      buyability_client: nil,
      state_store: StateStore.new(DEFAULT_STATE_PATH),
      catalog_store: CatalogStore.new(DEFAULT_CATALOG_PATH),
      control_store: nil,
      event_log: EventLog.new(DEFAULT_EVENT_LOG_PATH),
      alerter: Alerter.new,
      watch_urls: [],
      watch_candidates: [],
      open_matches: true,
      include_grid: true,
      fetch_threads: 6,
      reminder_interval_seconds: StateStore::DEFAULT_REMINDER_INTERVAL_SECONDS,
      call_interval_seconds: StateStore::DEFAULT_CALL_INTERVAL_SECONDS,
      now: -> { Time.now.utc }
    )
      @grid_url = grid_url
      @fetcher = fetcher
      @parser = parser
      @matcher = matcher
      @buyability = buyability
      @buyability_client = buyability_client || BuyabilityClient.new(fetcher: fetcher)
      @state_store = state_store
      @catalog_store = catalog_store
      @control_store = control_store
      @event_log = event_log
      @alerter = alerter
      @watch_urls = watch_urls
      @watch_candidates = watch_candidates
      @open_matches = open_matches
      @include_grid = include_grid
      @fetch_threads = [fetch_threads.to_i, 1].max
      @reminder_interval_seconds = reminder_interval_seconds
      @call_interval_seconds = call_interval_seconds
      @now = now
    end

    def run
      checked_at = @now.call
      started_at = monotonic_time
      warnings = []
      direct_html_by_url = {}
      matcher = current_matcher
      grid_result = grid_candidates(warnings)
      grid_candidates = grid_result.fetch(:candidates)
      catalog_candidates = current_watch_candidates
      legacy_pdp_mode = catalog_candidates.empty?
      direct_result = if catalog_candidates.empty?
        direct_candidates(direct_html_by_url, warnings)
      else
        { candidates: catalog_candidates, watch_urls: catalog_candidates.length, failures: 0, failed_part_numbers: [] }
      end
      catalog_candidates = direct_result.fetch(:candidates)
      candidates = unique_candidates(grid_candidates + catalog_candidates)
      target_candidates = candidates.select { |candidate| matcher.target_model?(candidate) }
      eligible_candidates = target_candidates.select { |candidate| matcher.eligible?(candidate) }
      merge_catalog_candidates(grid_candidates.select { |candidate| matcher.eligible?(candidate) }, checked_at)
      verified = if legacy_pdp_mode
        verify_candidates_from_pdp(eligible_candidates, direct_html_by_url)
      else
        verify_candidates(eligible_candidates, checked_at)
      end
      confirmed_buyable = verified.fetch(:confirmed_buyable)
      availability_signals = verified.fetch(:availability_signals)
      unconfirmed = verified.fetch(:unconfirmed)
      verified_not_buyable = verified.fetch(:verified_not_buyable)
      warnings.concat(verified.fetch(:warnings))

      target_unique = unique_candidates(target_candidates)
      eligible_unique = unique_candidates(eligible_candidates)
      confirmed_unique = unique_candidates(confirmed_buyable)
      availability_signal_unique = unique_candidates(availability_signals)
      unconfirmed_unique = unique_candidates(unconfirmed)
      verified_not_buyable_unique = unique_candidates(verified_not_buyable)
      duration_seconds = monotonic_time - started_at

      state = @state_store.load
      check_summary = {
        "total_tiles" => grid_candidates.length,
        "direct_watch_urls" => direct_result.fetch(:watch_urls),
        "direct_watch_candidates" => catalog_candidates.length,
        "direct_watch_failures" => direct_result.fetch(:failures),
        "target_tiles" => target_unique.length,
        "eligible_target_tiles" => eligible_unique.length,
        "confirmed_buyable" => confirmed_unique.length,
        "availability_signals" => availability_signal_unique.length,
        "verified_not_buyable" => verified_not_buyable_unique.length,
        "unconfirmed_candidates" => unconfirmed_unique.length,
        "warnings" => warnings.length,
        "duration_seconds" => duration_seconds.round(3),
        "grid_failed" => grid_result.fetch(:failed),
        "grid_metadata" => grid_result.fetch(:metadata),
        "buyability_failed" => verified.fetch(:surface_failed),
        "buyability_metadata" => verified.fetch(:metadata)
      }
      alerts = @state_store.alertable_candidates(
        state: state,
        visible_candidates: eligible_unique,
        listed_candidates: legacy_pdp_mode ? [] : grid_candidates.select { |candidate| matcher.eligible?(candidate) },
        buyable_candidates: confirmed_unique,
        availability_signal_candidates: availability_signal_unique,
        not_buyable_candidates: verified_not_buyable_unique,
        unconfirmed_part_numbers: direct_result.fetch(:failed_part_numbers),
        checked_at: checked_at,
        check_summary: check_summary,
        reminder_interval_seconds: @reminder_interval_seconds,
        call_interval_seconds: @call_interval_seconds,
        confirm_calls: !legacy_pdp_mode && alert_channel_available?("twilio_call"),
        listing_surface_checked: !legacy_pdp_mode && !grid_result.fetch(:failed)
      )

      muted = muted_channels
      alert_events = alerts.map { |candidate| ladder_event(candidate, checked_at) }
      alerts.each do |candidate|
        next unless @open_matches

        alert_result = alert_candidate(candidate, muted: muted)
        if alert_result.receipts.any?
          @state_store.record_alert_attempt(state, candidate, alert_result.receipts, attempted_at: checked_at)
          alert_events.concat(alert_attempt_events(candidate, alert_result.receipts, checked_at))
        elsif alert_result.suppressed_channels.any?
          alert_events.concat(suppress_paused_alert(state, candidate, checked_at))
        end
      end

      # Alert state must be durable before observability writes: an event-log
      # failure after a browser open or SMS would otherwise replay the same
      # alert on every supervised restart.
      @state_store.save(state)
      record_pass(checked_at, check_summary, warnings, verified.fetch(:verdict_events), alert_events)

      Result.new(
        checked_at: checked_at,
        total_tiles: grid_candidates.length,
        direct_watch_candidates: catalog_candidates.length,
        target_tiles: target_unique.length,
        eligible_target_tiles: eligible_unique.length,
        confirmed_buyable: confirmed_unique,
        availability_signals: availability_signal_unique,
        unconfirmed_candidates: unconfirmed_unique,
        alerts: alerts,
        warnings: warnings,
        duration_seconds: duration_seconds
      )
    end

    private

    def grid_candidates(warnings)
      return { candidates: [], metadata: {}, failed: false } unless @include_grid

      response = if @fetcher.respond_to?(:get_with_metadata)
        @fetcher.get_with_metadata(@grid_url)
      else
        FetchResult.new(body: @fetcher.get(@grid_url), headers: {}, code: "200")
      end
      grid_html = response.body
      grid = @parser.grid_from_html(grid_html)
      {
        candidates: @parser.candidates_from_grid(grid, @grid_url),
        metadata: surface_metadata(response),
        failed: false
      }
    rescue Error => error
      warnings << "grid_unconfirmed error=#{error.message.inspect}"
      { candidates: [], metadata: {}, failed: true }
    end

    def direct_candidates(direct_html_by_url, warnings)
      urls = current_watch_urls
      return { candidates: [], watch_urls: 0, failures: 0, failed_part_numbers: [] } if urls.empty?

      mutex = Mutex.new
      queue = Queue.new
      urls.each { |url| queue << url }
      candidates = []
      failures = 0
      failed_part_numbers = []
      worker_count = [@fetch_threads, urls.length].min

      worker_count.times.map do
        Thread.new do
          loop do
            url = queue.pop(true)
            html = @fetcher.get(url)
            candidate = @parser.candidate_from_pdp(html, url)

            mutex.synchronize do
              direct_html_by_url[url] = html
              if candidate
                candidates << candidate
              else
                failures += 1
                failed_part_numbers << Config.product_part_number(url)
                warnings << "watch_url_unconfirmed url=#{url.inspect} error=\"no candidate parsed\""
              end
            end
          rescue ThreadError
            break
          rescue Error => error
            mutex.synchronize do
              failures += 1
              failed_part_numbers << Config.product_part_number(url)
              warnings << "watch_url_unconfirmed url=#{url.inspect} error=#{error.message.inspect}"
            end
          end
        end
      end.each(&:join)

      {
        candidates: candidates,
        watch_urls: urls.length,
        failures: failures,
        failed_part_numbers: failed_part_numbers.compact.uniq
      }
    end

    def verify_candidates(candidates, checked_at)
      candidates_by_part = candidates.to_h { |candidate| [candidate.part_number.upcase, candidate] }
      confirmed_buyable = []
      availability_signals = []
      unconfirmed = []
      verified_not_buyable = []
      warnings = []
      verdict_events = []

      result = @buyability_client.fetch(candidates_by_part.keys)
      flags = result.flags
      candidates_by_part.each do |part_number, candidate|
        if flags.key?(part_number)
          if flags.fetch(part_number)
            confirmed_buyable << candidate
            verdict_events << endpoint_verdict_event(candidate, "buyable", result.metadata)
          else
            verified_not_buyable << candidate
            verdict_events << endpoint_verdict_event(candidate, "not_buyable", result.metadata)
          end
        else
          fallback = verify_missing_buyability_flag(candidate, checked_at)
          verdict_events << fallback.fetch(:event)
          case fallback.fetch(:verdict)
          when "buyable"
            confirmed_buyable << candidate
          when "availability_signal"
            availability_signals << candidate_with_alert_kind(candidate, "availability_signal")
          when "not_buyable"
            verified_not_buyable << candidate
          when "retired"
            verified_not_buyable << candidate
          else
            unconfirmed << candidate
            warnings << "#{candidate.part_number}: candidate_unconfirmed missing buyability flag"
          end
        end
      end

      {
        confirmed_buyable: confirmed_buyable,
        availability_signals: availability_signals,
        unconfirmed: unconfirmed,
        verified_not_buyable: verified_not_buyable,
        warnings: warnings,
        verdict_events: verdict_events,
        surface_failed: false,
        metadata: result.metadata
      }
    rescue Error => error
      candidates.each do |candidate|
        unconfirmed << candidate
        warnings << "#{candidate.part_number}: buyability_surface_unconfirmed #{error.message}"
        verdict_events << endpoint_verdict_event(candidate, "unconfirmed", {}, error: error.message)
      end

      {
        confirmed_buyable: confirmed_buyable,
        availability_signals: [],
        unconfirmed: unconfirmed,
        verified_not_buyable: verified_not_buyable,
        warnings: warnings,
        verdict_events: verdict_events,
        surface_failed: true,
        metadata: {}
      }
    end

    def verify_missing_buyability_flag(candidate, checked_at)
      pdp_html = @fetcher.get(candidate.url)
      verdict = @buyability.confirm(pdp_html)
      event = verdict_event(candidate, verdict, source: "pdp_fallback", error: "missing buyability flag")

      if verdict.buyable?
        { verdict: "buyable", event: event }
      elsif verdict.availability_signal?
        { verdict: "availability_signal", event: event }
      elsif verdict.ambiguous?
        retire_or_unconfirm_missing_flag(candidate, checked_at, event)
      else
        { verdict: "not_buyable", event: event }
      end
    rescue Error => error
      event = endpoint_verdict_event(candidate, "unconfirmed", {}, error: "missing buyability flag; #{error.message}")
      retire_or_unconfirm_missing_flag(candidate, checked_at, event)
    end

    def retire_or_unconfirm_missing_flag(candidate, checked_at, event)
      if stale_catalog_candidate?(candidate, checked_at)
        retire_catalog_candidate(candidate, checked_at, "missing_buyability_flag")
        { verdict: "retired", event: event.merge("verdict" => "retired") }
      else
        { verdict: "unconfirmed", event: event }
      end
    end

    def stale_catalog_candidate?(candidate, checked_at)
      product = catalog_product(candidate)
      last_seen_at = product && parse_catalog_time(product["last_seen_at"])
      last_seen_at && checked_at - last_seen_at > STALE_CATALOG_SECONDS
    end

    def catalog_product(candidate)
      @catalog_store.products.find { |product| product["part_number"] == candidate.part_number }
    rescue Error
      nil
    end

    def parse_catalog_time(value)
      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def retire_catalog_candidate(candidate, checked_at, reason)
      @catalog_store.update do |previous|
        by_part = previous.fetch("products", []).to_h { |product| [product.fetch("part_number"), product] }
        product = by_part[candidate.part_number]
        next unless product && product["retired_at"].to_s.empty?

        checked_at_iso = checked_at.iso8601
        by_part[candidate.part_number] = product.merge(
          "retired_at" => checked_at_iso,
          "retired_reason" => reason
        )
        {
          "updated_at" => checked_at_iso,
          "products" => by_part.values.sort_by { |item| item.fetch("part_number") }
        }
      end
    rescue Error
      nil
    end

    def verify_candidates_from_pdp(candidates, direct_html_by_url)
      mutex = Mutex.new
      queue = Queue.new
      candidates.each { |candidate| queue << candidate }
      confirmed_buyable = []
      availability_signals = []
      unconfirmed = []
      verified_not_buyable = []
      warnings = []
      verdict_events = []
      worker_count = [@fetch_threads, candidates.length].min

      worker_count.times.map do
        Thread.new do
          loop do
            candidate = queue.pop(true)
            pdp_html = direct_html_by_url.fetch(candidate.url) { @fetcher.get(candidate.url) }
            verdict = @buyability.confirm(pdp_html)
            verdict_event = verdict_event(candidate, verdict)

            mutex.synchronize do
              verdict_events << verdict_event
              if verdict.buyable?
                confirmed_buyable << candidate
              elsif verdict.availability_signal?
                availability_signals << candidate_with_alert_kind(candidate, "availability_signal")
              elsif verdict.ambiguous?
                unconfirmed << candidate
                warnings << "#{candidate.part_number}: candidate_ambiguous #{verdict.reason}"
              else
                verified_not_buyable << candidate
              end
            end
          rescue ThreadError
            break
          rescue Error => error
            mutex.synchronize do
              unconfirmed << candidate
              warnings << "#{candidate.part_number}: candidate_unconfirmed #{error.message}"
              verdict_events << {
                "type" => "buyability_verdict",
                "part_number" => candidate.part_number,
                "title" => candidate.title,
                "url" => candidate.url,
                "verdict" => "unconfirmed",
                "error" => error.message,
                "positive_signals" => [],
                "negative_signals" => []
              }
            end
          end
        end
      end.each(&:join)

      {
        confirmed_buyable: confirmed_buyable,
        availability_signals: availability_signals,
        unconfirmed: unconfirmed,
        verified_not_buyable: verified_not_buyable,
        warnings: warnings,
        verdict_events: verdict_events,
        surface_failed: false,
        metadata: {}
      }
    end

    def endpoint_verdict_event(candidate, verdict, metadata, error: nil)
      {
        "type" => "buyability_verdict",
        "part_number" => candidate.part_number,
        "title" => candidate.title,
        "url" => candidate.url,
        "verdict" => verdict,
        "source" => "buyability_message",
        "error" => error,
        "positive_signals" => verdict == "buyable" ? ["is_buyable_true"] : [],
        "negative_signals" => verdict == "not_buyable" ? ["is_buyable_false"] : [],
        "metadata" => metadata
      }.compact
    end

    def verdict_event(candidate, verdict, source: "pdp", error: nil)
      {
        "type" => "buyability_verdict",
        "part_number" => candidate.part_number,
        "title" => candidate.title,
        "url" => candidate.url,
        "verdict" => verdict_label(verdict),
        "source" => source,
        "error" => error,
        "positive_signals" => verdict.positive_signals,
        "negative_signals" => verdict.negative_signals
      }.compact
    end

    def record_pass(checked_at, check_summary, warnings, verdict_events, alert_events = [])
      checked_count = check_summary.fetch("direct_watch_urls", 0)
      checked_count = check_summary.fetch("eligible_target_tiles", 0) unless checked_count.positive?
      problem_count = check_summary.fetch("direct_watch_failures", 0) + check_summary.fetch("unconfirmed_candidates", 0)
      mass_failure = checked_count.positive? && problem_count.to_f / checked_count >= 0.5

      events = verdict_events.map { |event| event.merge("checked_at" => checked_at.iso8601) }
      events.concat(alert_events)
      events << {
        "type" => "check_pass",
        "checked_at" => checked_at.iso8601,
        "summary" => check_summary,
        "warnings" => warnings
      }
      if check_summary["grid_failed"]
        events << {
          "type" => "surface_failure_alarm",
          "checked_at" => checked_at.iso8601,
          "surface" => "grid",
          "warnings" => warnings
        }
      end
      if check_summary["buyability_failed"]
        events << {
          "type" => "surface_failure_alarm",
          "checked_at" => checked_at.iso8601,
          "surface" => "buyability",
          "warnings" => warnings
        }
      end
      if mass_failure
        events << {
          "type" => "mass_failure_alarm",
          "checked_at" => checked_at.iso8601,
          "direct_watch_urls" => check_summary.fetch("direct_watch_urls", 0),
          "direct_watch_failures" => check_summary.fetch("direct_watch_failures", 0),
          "unconfirmed_candidates" => check_summary.fetch("unconfirmed_candidates"),
          "eligible_target_tiles" => check_summary.fetch("eligible_target_tiles"),
          "problem_count" => problem_count,
          "checked_count" => checked_count,
          "warnings" => warnings
        }
      end
      @event_log.append_many(events)
    rescue StandardError => error
      # Observability must never take down detection: state is already saved,
      # so a failed event write costs forensic data, not alerts.
      warnings << "event_log_unconfirmed error=#{error.message.inspect}"
    end

    def muted_channels
      @control_store ? @control_store.muted_channels : []
    end

    def alert_candidate(candidate, muted: [])
      if @alerter.respond_to?(:alert_with_receipts)
        @alerter.alert_with_receipts(candidate, channels: alert_channels(candidate), muted: muted)
      else
        AlertResult.from_boolean(@alerter.alert(candidate), channel: @alerter.class.name.split("::").last)
      end
    end

    def suppress_paused_alert(state, candidate, checked_at)
      if candidate.alert_kind.to_s.empty?
        # The phone call gates on buyable_alerted_at, so a fully muted buyable
        # alert must still advance the ladder or the call never rings. Record
        # a synthetic paused receipt: it marks buyable_alerted_at
        # and stays auditable in alert_attempts.
        receipt = AlertReceipt.new(channel: "paused", success: true)
        @state_store.record_alert_attempt(state, candidate, [receipt], attempted_at: checked_at)
        alert_attempt_events(candidate, [receipt], checked_at)
      else
        # listing is a one-shot edge; reminder and the call re-evaluate on
        # cadence. Skipping with no record lets them fire on resume while the
        # part is still buyable, and drops the spent listing edge.
        [suppressed_event(candidate, checked_at)]
      end
    end

    def alert_channels(candidate)
      case candidate.alert_kind
      when "listing"
        %w[twilio_sms]
      when "confirmed_buyable_call"
        %w[twilio_call]
      when "reminder"
        %w[twilio_sms]
      else
        %w[browser command twilio_sms]
      end
    end

    def alert_channel_available?(key)
      if @alerter.respond_to?(:alerts_channel?)
        @alerter.alerts_channel?(key)
      else
        true
      end
    end

    def alert_attempt_events(candidate, receipts, checked_at)
      receipts.map do |receipt|
        {
          "type" => "alert_attempt",
          "checked_at" => checked_at.iso8601,
          "part_number" => candidate.part_number,
          "title" => candidate.title,
          "url" => candidate.url,
          "alert_kind" => candidate.alert_kind,
          "channel" => receipt.channel,
          "success" => receipt.success?,
          "provider_id" => receipt.provider_id,
          "error" => receipt.error
        }.compact
      end
    end

    def suppressed_event(candidate, checked_at)
      {
        "type" => "alert_suppressed",
        "checked_at" => checked_at.iso8601,
        "part_number" => candidate.part_number,
        "title" => candidate.title,
        "url" => candidate.url,
        "alert_kind" => candidate.alert_kind.to_s.empty? ? "buyable" : candidate.alert_kind,
        "reason" => "channel_paused"
      }
    end

    def ladder_event(candidate, checked_at)
      kind = candidate.alert_kind.to_s.empty? ? "buyable" : candidate.alert_kind
      type = case kind
      when "listing"
        "listing_event"
      when "confirmed_buyable_call"
        "confirming_recheck"
      when "reminder"
        "reminder_event"
      else
        "buyability_flip"
      end

      {
        "type" => type,
        "checked_at" => checked_at.iso8601,
        "part_number" => candidate.part_number,
        "title" => candidate.title,
        "url" => candidate.url,
        "alert_kind" => kind
      }
    end

    def verdict_label(verdict)
      if verdict.buyable?
        "buyable"
      elsif verdict.availability_signal?
        "availability_signal"
      elsif verdict.ambiguous?
        "ambiguous"
      else
        "not_buyable"
      end
    end

    def current_watch_urls
      urls = @watch_urls.respond_to?(:call) ? @watch_urls.call : @watch_urls
      urls.map(&:to_s).reject(&:empty?).uniq
    end

    def current_watch_candidates
      candidates = @watch_candidates.respond_to?(:call) ? @watch_candidates.call : @watch_candidates
      candidates.compact.uniq(&:part_number)
    end

    # Criteria are hot: a callable matcher re-reads targets.json every pass,
    # so edits take effect within one sweep without a restart or deploy.
    def current_matcher
      @matcher.respond_to?(:call) ? @matcher.call : @matcher
    end

    def merge_catalog_candidates(candidates, checked_at)
      return if candidates.empty?

      @catalog_store.update do |previous|
        by_part = previous.fetch("products", []).to_h { |product| [product.fetch("part_number"), product] }
        checked_at_iso = checked_at.iso8601
        changed = false

        candidates.each do |candidate|
          previous_product = by_part[candidate.part_number] || {}
          next_product = {
            "part_number" => candidate.part_number,
            "title" => candidate.title,
            "url" => RefurbRadar.short_product_url(candidate.part_number),
            "model" => candidate.model,
            "memory" => candidate.memory,
            "capacity" => candidate.capacity,
            "price" => candidate.price,
            "screen_size_inches" => candidate.screen_size_inches,
            "chip_family" => candidate.chip_family,
            "source_url" => candidate.url,
            "first_discovered_at" => previous_product["first_discovered_at"] || checked_at_iso,
            "last_seen_at" => checked_at_iso
          }.compact
          comparable_previous = previous_product.reject { |key, _value| key == "last_seen_at" }
          comparable_next = next_product.reject { |key, _value| key == "last_seen_at" }
          next if comparable_previous == comparable_next

          changed = true
          by_part[candidate.part_number] = next_product
        end

        if changed
          {
            "updated_at" => checked_at_iso,
            "products" => by_part.values.sort_by { |product| product.fetch("part_number") }
          }
        end
      end
    rescue Error
      nil
    end

    def surface_metadata(response)
      {
        "code" => response.code,
        "server_timing" => response.headers["server-timing"],
        "cache_control" => response.headers["cache-control"],
        "x_cache" => response.headers["x-cache"],
        "duration_seconds" => response.duration_seconds&.round(3)
      }.compact
    end

    def candidate_with_alert_kind(candidate, alert_kind)
      Candidate.new(
        part_number: candidate.part_number,
        title: candidate.title,
        url: candidate.url,
        model: candidate.model,
        memory: candidate.memory,
        capacity: candidate.capacity,
        price: candidate.price,
        commit_string: candidate.commit_string,
        screen_size_inches: candidate.screen_size_inches,
        chip_family: candidate.chip_family,
        alert_kind: alert_kind
      )
    end

    def unique_candidates(candidates)
      candidates.each_with_object({}) do |candidate, by_part_number|
        by_part_number[candidate.part_number] = candidate
      end.values
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  class Watch
    def initialize(
      check: Check.new,
      sleep_range: 24..38,
      output: $stdout,
      sleeper: Kernel,
      max_checks: nil,
      catalog_refresh: nil,
      catalog_refresh_interval: 1800,
      now: -> { Time.now.utc }
    )
      @check = check
      @sleep_range = sleep_range
      @output = output
      @sleeper = sleeper
      @max_checks = max_checks
      @catalog_refresh = catalog_refresh
      @catalog_refresh_interval = catalog_refresh_interval
      @now = now
      @last_catalog_refresh_at = nil
      @catalog_refresh_thread = nil
      @catalog_refresh_mutex = Mutex.new
      @stopped = false
    end

    def run
      trap_signals
      checks = 0

      until @stopped
        begin
          result = @check.run
          checks += 1
          @output.puts Formatter.summary(result)
          result.alerts.each { |candidate| @output.puts Formatter.alert(candidate) }
          result.warnings.each { |warning| @output.puts "warning=#{warning}" }
          refresh_catalog_if_due
        rescue StandardError => error
          # Supervisor boundary: an unexpected exception must log and continue,
          # not kill the process into a launchd/Kamal restart-and-replay loop.
          @output.puts "error=#{error.class}: #{error.message}"
        end

        break if @stopped
        break if @max_checks && checks >= @max_checks

        @sleeper.sleep(rand(@sleep_range))
      end
    ensure
      join_catalog_refresh
    end

    private

    def refresh_catalog_if_due
      return unless @catalog_refresh
      return unless catalog_refresh_due?

      @catalog_refresh_mutex.synchronize do
        return if @catalog_refresh_thread&.alive?
        return unless catalog_refresh_due?

        @last_catalog_refresh_at = @now.call
        @catalog_refresh_thread = Thread.new do
          begin
            result = @catalog_refresh.run
            @output.puts Formatter.catalog_refresh_summary(result)
            result.warnings.each { |warning| @output.puts "warning=#{warning}" }
          rescue Error => error
            @output.puts "warning=catalog_refresh_unconfirmed error=#{error.message.inspect}"
          end
        end
      end
    end

    def catalog_refresh_due?
      return false if @catalog_refresh_thread&.alive?
      return true unless @last_catalog_refresh_at
      return false unless @catalog_refresh_interval&.positive?

      @now.call - @last_catalog_refresh_at >= @catalog_refresh_interval
    end

    def join_catalog_refresh
      @catalog_refresh_thread&.join
    end

    def trap_signals
      %w[INT TERM].each do |signal|
        Signal.trap(signal) { @stopped = true }
      rescue ArgumentError
        next
      end
    end
  end

  module Formatter
    module_function

    def summary(result)
      [
        "checked_at=#{result.checked_at.iso8601}",
        "tiles=#{result.total_tiles}",
        "direct_watch_candidates=#{result.direct_watch_candidates || 0}",
        "target_tiles=#{result.target_tiles}",
        "eligible_target_tiles=#{result.eligible_target_tiles}",
        "confirmed_buyable=#{result.confirmed_buyable.length}",
        "alerts=#{result.alerts.length}",
        "warnings=#{result.warnings.length}",
        "duration=#{format("%.3f", result.duration_seconds || 0)}s"
      ].join(" ")
    end

    def alert(candidate)
      "ALERT part=#{candidate.part_number} title=#{candidate.title.inspect} url=#{candidate.url}"
    end

    def catalog_refresh_summary(result)
      products = result.catalog.fetch("products", [])
      [
        "catalog_refreshed_at=#{result.checked_at.iso8601}",
        "discovered_candidates=#{result.discovered_candidates.length}",
        "catalog_products=#{products.length}",
        "warnings=#{result.warnings.length}"
      ].join(" ")
    end
  end
end
