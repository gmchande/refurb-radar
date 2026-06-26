# frozen_string_literal: true

require "json"
require "time"

module RefurbRadar
  class InventorySnapshot
    DOWN_SECONDS = 300

    DEFAULT_TARGETS_PATH = File.expand_path("../../config/targets.json", __dir__)

    CONTROLLABLE_CHANNELS = [
      { key: "twilio_call", label: "calls" },
      { key: "twilio_sms", label: "texts" },
      { key: "browser", label: "browser" }
    ].freeze

    STORY_TYPES = %w[listing_event buyability_flip alert_attempt alert_suppressed].freeze
    def initialize(state_path:, catalog_path:, control_store: nil, event_log: NullEventLog.new,
                   targets_path: DEFAULT_TARGETS_PATH, test_receipt_path: nil,
                   public_url: nil, base_path: "", env: ENV, now: -> { Time.now.utc })
      @state_path = state_path
      @catalog_path = catalog_path
      @control_store = control_store
      @event_log = event_log
      @targets_path = targets_path
      @test_receipt_path = test_receipt_path
      @public_url = public_url
      @base_path = base_path.to_s.sub(%r{/+\z}, "")
      @env = env
      @now = now
    end

    def to_h
      state, state_error = read_json(@state_path, StateStore::EMPTY_STATE)
      catalog, catalog_error = read_json(@catalog_path, CatalogStore::EMPTY_CATALOG)
      seen = state.fetch("currently_seen", {})
      history = state.fetch("history", [])
      products = catalog.fetch("products", [])
      active_products = products.select { |product| Config.active_product?(product) }
      products_by_part = products.to_h { |product| [product["part_number"], product] }
      stats = state.fetch("stats", {})
      last_check = stats.fetch("last_check", {})
      last_checked_at = parse_time(state["last_checked_at"] || last_check["checked_at"])
      controls = control_status
      muted = controls.select { |channel| channel[:paused] }
      test = test_receipt
      drop = drop_rows(seen, products_by_part)
      watch_summary = watch_summary(seen, last_check)
      events = story_events(seen, history)
      story_parts = watched_story_parts(products_by_part, seen, history, events)
      scoped_seen = seen.select { |part, _| story_parts.include?(part) }
      scoped_history = history.select { |record| story_parts.include?(record["part_number"]) }
      scoped_events = events.select { |event| story_parts.include?(event["part_number"]) }

      {
        generated_at: @now.call,
        public_url: @public_url,
        base_path: @base_path,
        state: state,
        catalog: catalog,
        seen: seen,
        history: history,
        products: products,
        active_products: active_products,
        products_by_part: products_by_part,
        events: events,
        scoped_seen: scoped_seen,
        scoped_history: scoped_history,
        scoped_events: scoped_events,
        last_check: last_check,
        last_checked_at: last_checked_at,
        verdict: verdict(last_checked_at, muted, drop),
        hunting: hunting_line,
        watch_summary: watch_summary,
        pass_seconds: last_check["duration_seconds"],
        controls: controls,
        chain: chain(last_checked_at, last_check, scoped_seen, scoped_history, controls, test, watch_summary),
        test: test,
        drop: drop,
        catalog_updated_at: parse_time(catalog["updated_at"]),
        catalog_known: products.any?,
        faults: [state_error, catalog_error].compact
      }
    end

    private
      def watch_summary(seen, last_check)
        available = seen.values.count { |record| record["last_buyable_at"] }
        listed = seen.values.count { |record| record["listed_present"] }
        checked = last_check["eligible_target_tiles"] || seen.length

        {
          checked: checked.to_i,
          listed: listed,
          available: available
        }
      end

      def verdict(last_checked_at, muted, drop)
        if last_checked_at.nil?
          { headline: "Standing by.", detail: "No checks recorded yet.", tone: "dim" }
        elsif @now.call - last_checked_at > DOWN_SECONDS
          { headline: "Watcher down.",
            detail: "Hasn't checked the store for #{duration(@now.call - last_checked_at)}.",
            tone: "down" }
        elsif drop.any? && muted.any?
          { headline: "Drop in progress — and #{mute_phrase(muted)} muted.",
            detail: "Buyable Macs below. Unmute or act now.", tone: "down" }
        elsif drop.any?
          { headline: "Drop in progress — #{drop.length} buyable.",
            detail: "You were alerted. Pick one below.", tone: "drop" }
        elsif muted.any?
          { headline: "#{mute_phrase(muted).capitalize} muted#{mute_until(muted)}.",
            detail: "You will not get #{muted.map { |channel| channel[:label] }.join(" or ")}. The store is still being checked.",
            tone: "muted" }
        else
          { headline: "On watch.", detail: nil, tone: "ok" }
        end
      end

      def mute_phrase(muted)
        muted.map { |channel| channel[:label] }.join(" & ")
      end

      def mute_until(muted)
        return "" if muted.length != 1

        channel = muted.first
        if channel[:indefinite]
          " until you resume"
        elsif channel[:paused_until]
          " until #{clock_minute(channel[:paused_until])}"
        else
          ""
        end
      end

      # Rules with identical constraints read as one promise ("Mac mini &
      # Mac Studio · 64GB+ RAM ...") even though they are separate rules.
      def hunting_line
        targets, = read_json(@targets_path, { "rules" => [] })
        segments = targets.fetch("rules", []).map do |rule|
          [Array(rule["models"]).map { |model| model_label(model) },
           clause_parts(
             rule["min_memory_gb"],
             rule["max_memory_gb"],
             rule["min_cpu_cores"],
             rule["max_capacity_gb"],
             rule["max_price"],
             rule["screen_size_inches"],
             rule["chip_family"]
           )]
        end
        merged = segments.group_by(&:last).map do |clauses, group|
          models = group.flat_map(&:first).uniq
          parts = models.empty? ? clauses : [models.join(" & ")] + clauses
          parts.join(" · ")
        end.reject(&:empty?)
        merged.empty? ? nil : merged.join("; ")
      end

      def clause_parts(min_memory, max_memory, cores, capacity, price, screen_size = nil, chip_family = nil)
        parts = []
        parts << "#{format_screen_size(screen_size)}" if screen_size
        parts << "#{format_chip_family(chip_family)} chip" if chip_family
        parts << memory_clause(min_memory, max_memory) if min_memory || max_memory
        parts << "#{cores}-core+ CPU" if cores
        parts << "up to #{format_gb(capacity)} SSD" if capacity
        parts << "under #{format_price(price)}" if price
        parts
      end

      def memory_clause(min_memory, max_memory)
        if min_memory && max_memory
          min_memory == max_memory ? "#{min_memory}GB RAM" : "#{min_memory}-#{max_memory}GB RAM"
        elsif min_memory
          "#{min_memory}GB+ RAM"
        else
          "up to #{max_memory}GB RAM"
        end
      end

      def control_status
        status = @control_store ? @control_store.status : {}
        CONTROLLABLE_CHANNELS.map do |channel|
          state = status[channel[:key]] || {}
          configured = channel_configured?(channel[:key])
          {
            key: channel[:key],
            label: channel[:label],
            configured: configured,
            paused: configured && state["paused"] ? true : false,
            paused_until: parse_time(state["paused_until"]),
            indefinite: state["paused_until"] == ControlStore::INDEFINITE
          }
        end
      end

      def channel_configured?(key)
        case key
        when "twilio_call"
          RefurbRadar.env_fetch(@env, "REFURB_RADAR_TWILIO_CALL", "0") == "1"
        when "twilio_sms"
          RefurbRadar.env_fetch(@env, "REFURB_RADAR_TWILIO_SMS", "0") == "1"
        when "browser"
          RefurbRadar.env_fetch(@env, "REFURB_RADAR_BROWSER_ALERT", "1") != "0"
        else
          true
        end
      end

      def watched_story_parts(products_by_part, seen, history, events)
        models = watched_models
        return [] if models.empty?

        parts = []
        products_by_part.each do |part, product|
          parts << part if models.include?(product["model"])
        end
        (seen.values + history).each do |record|
          parts << record["part_number"] if models.include?(record_model(record, products_by_part[record["part_number"]]))
        end
        events.each do |event|
          parts << event["part_number"] if models.include?(record_model(event, products_by_part[event["part_number"]]))
        end
        parts.compact.uniq
      rescue Error
        (seen.keys + history.map { |record| record["part_number"] } + events.map { |event| event["part_number"] }).compact.uniq
      end

      def watched_models
        Matcher.rules_from_file(@targets_path).flat_map(&:models).uniq
      end

      def record_model(record, product)
        product && product["model"] || model_from_title(record["title"])
      end

      def model_from_title(title)
        normalized = title.to_s.downcase
        if normalized.include?("mac studio")
          "macstudio"
        elsif normalized.include?("mac mini")
          "macmini"
        elsif normalized.include?("macbook pro")
          "macbookpro"
        elsif normalized.include?("macbook air")
          "macbookair"
        elsif normalized.include?("mac pro")
          "macpro"
        elsif normalized.include?("imac")
          "imac"
        end
      end

      def recorded_events
        @event_log.tail(EventLog::DEFAULT_MAX_EVENTS).select { |event| STORY_TYPES.include?(event["type"]) }
      rescue StandardError
        []
      end

      def story_events(seen, history)
        events = recorded_events + state_alert_attempt_events(seen, history)
        indexed = {}
        events.each { |event| indexed[event_key(event)] ||= event }
        indexed.values.sort_by { |event| parse_time(event["checked_at"]) || Time.at(0).utc }
      end

      def state_alert_attempt_events(seen, history)
        (seen.values + history).flat_map do |record|
          Array(record["alert_attempts"]).filter_map do |attempt|
            next if attempt["attempted_at"].to_s.empty?

            {
              "type" => "alert_attempt",
              "checked_at" => attempt["attempted_at"],
              "part_number" => record["part_number"],
              "title" => record["title"],
              "url" => record["url"],
              "channel" => attempt["channel"],
              "success" => attempt["success"] ? true : false,
              "provider_id" => attempt["provider_id"],
              "error" => attempt["error"]
            }.compact
          end
        end
      end

      def event_key(event)
        [
          event["type"],
          event["checked_at"],
          event["part_number"],
          event["channel"]
        ]
      end

      def chain(last_checked_at, last_check, seen, history, controls, test, watch_summary)
        records = seen.values + history
        [
          sweep_link(last_checked_at),
          listing_link(records, last_check, watch_summary),
          verify_link(last_checked_at, last_check, watch_summary),
          channel_link("texts", "twilio_sms", records, controls, test),
          channel_link("calls", "twilio_call", records, controls, test),
          channel_link("browser", "browser", records, controls, test)
        ]
      end

      def sweep_link(last_checked_at)
        if last_checked_at.nil?
          { label: "checked", state: "unknown", note: "no checks yet" }
        elsif @now.call - last_checked_at > DOWN_SECONDS
          { label: "checked", state: "dead", note: "stopped #{duration(@now.call - last_checked_at)} ago" }
        else
          { label: "checked", state: "ok", note: "", epoch: last_checked_at.to_i }
        end
      end

      def listing_link(records, last_check, watch_summary)
        latest = records.select { |record| record["listed_present"] }
                        .filter_map { |record| parse_time(record["last_listed_at"] || record["first_detected_at"]) }
                        .max
        if last_check["grid_failed"]
          { label: "Showing", state: "warn", note: "refurb page unavailable last check" }
        elsif watch_summary[:listed].positive?
          { label: "Showing", state: "ok", note: "#{watch_summary[:listed]} on the refurb page" }
        elsif latest
          { label: "Showing", state: "unknown", note: "none now · last seen #{day(latest)}" }
        else
          { label: "Showing", state: "unknown", note: "none on the refurb page now" }
        end
      end

      def verify_link(last_checked_at, last_check, watch_summary)
        if last_check.empty? || last_checked_at.nil?
          { label: "Buyable now", state: "unknown", note: "no checks yet" }
        elsif last_check["buyability_failed"]
          { label: "Buyable now", state: "warn", note: "couldn't verify last check" }
        else
          not_buyable = last_check["verified_not_buyable"].to_i
          checked = [watch_summary[:available] + not_buyable, watch_summary[:checked]].max
          if watch_summary[:available].positive?
            { label: "Buyable now", state: "ok", note: "#{watch_summary[:available]} buyable · #{checked - watch_summary[:available]} checked, not buyable" }
          else
            { label: "Buyable now", state: "ok", note: "nothing buyable · checked #{checked}, none buyable" }
          end
        end
      end

      def channel_link(label, key, records, controls, test)
        control = controls.find { |channel| channel[:key] == key }
        proven = last_send(key, records, test)
        if control && !control[:configured]
          { label: label, state: "off", note: "off by config" }
        elsif control && control[:paused]
          note = control[:indefinite] ? "muted until you resume" : "muted until #{clock_minute(control[:paused_until])}"
          { label: label, state: "muted", note: note }
        elsif proven
          { label: label, state: "ok", note: "sent #{day(proven)}" }
        else
          { label: label, state: "unknown", note: "never proven — run a test" }
        end
      end

      def last_send(channel, records, test)
        from_records = records.flat_map { |record| record["alert_attempts"] || [] }
                              .select { |attempt| attempt["channel"] == channel && attempt["success"] }
                              .filter_map { |attempt| parse_time(attempt["attempted_at"]) }
                              .max
        from_test = test && test[:receipts].find { |receipt| receipt[:channel] == channel && receipt[:success] } ? test[:tested_at] : nil
        [from_records, from_test].compact.max
      end

      def test_receipt
        return nil unless @test_receipt_path && File.exist?(@test_receipt_path)

        data = JSON.parse(File.read(@test_receipt_path, mode: "r:UTF-8"))
        {
          tested_at: parse_time(data["tested_at"]),
          receipts: Array(data["receipts"]).map do |receipt|
            { channel: receipt["channel"], success: receipt["success"] ? true : false, error: receipt["error"] }
          end
        }
      rescue JSON::ParserError, EncodingError
        nil
      end

      def drop_rows(seen, products_by_part)
        seen.values.select { |record| record["last_buyable_at"] }.map do |record|
          product = products_by_part[record["part_number"]] || {}
          {
            part_number: record["part_number"],
            spec: spec_line(product, record),
            price: format_price(product["price"]),
            url: product["url"] || record["url"] || RefurbRadar.short_product_url(record["part_number"]),
            buyable_since: parse_time(record["pending_call_at"] || record["last_buyable_at"]),
            actions: actions_taken(record)
          }
        end.sort_by { |row| row[:buyable_since] || @now.call }.reverse
      end

      def actions_taken(record)
        attempts = (record["alert_attempts"] || []).select { |attempt| attempt["success"] }
        actions = []
        called = attempts.select { |attempt| attempt["channel"] == "twilio_call" }.last
        texted = attempts.select { |attempt| attempt["channel"] == "twilio_sms" }.last
        actions << "called you #{clock(parse_time(called["attempted_at"]))} ✓" if called
        actions << "texted you ✓" if texted
        actions << "alerts were muted" if attempts.any? { |attempt| attempt["channel"] == "paused" }
        actions
      end

      def read_json(path, fallback)
        return [Marshal.load(Marshal.dump(fallback)), "#{path} missing"] unless File.exist?(path)

        [JSON.parse(File.read(path, mode: "r:UTF-8")), nil]
      rescue JSON::ParserError, EncodingError => error
        [Marshal.load(Marshal.dump(fallback)), "#{path}: #{error.message}"]
      end

      def parse_time(value)
        Time.parse(value.to_s).utc unless value.to_s.empty?
      rescue ArgumentError
        nil
      end

      def clean_title(title)
        title.to_s.sub(/\ARefurbished\s+/i, "").strip
      end

      def spec_line(product, record)
        parts = [
          product["model"] && model_label(product["model"]),
          format_screen_size(product_screen_size(product)),
          format_chip_family(product_chip_family(product)),
          format_memory(product["memory"]),
          format_capacity(product["capacity"])
        ].compact
        parts.empty? ? clean_title(product["title"] || record["title"]) : parts.join(" · ")
      end

      def product_screen_size(product)
        product["screen_size_inches"] || Config.screen_size_inches(product["title"])
      end

      def product_chip_family(product)
        product["chip_family"] || Config.chip_family_key(product["title"])
      end

      def model_label(model)
        {
          "macmini" => "Mac mini",
          "macstudio" => "Mac Studio",
          "macbookpro" => "MacBook Pro",
          "macbookair" => "MacBook Air",
          "imac" => "iMac",
          "macpro" => "Mac Pro",
          "visionpro" => "Apple Vision Pro"
        }.fetch(model.to_s, model.to_s)
      end

      def format_memory(memory)
        memory.to_s =~ /\A(\d+)gb\z/ ? "#{$1}GB" : memory
      end

      def format_capacity(capacity)
        case capacity.to_s
        when /\A(\d+)gb\z/ then "#{$1}GB"
        when /\A(\d+)tb\z/ then "#{$1}TB"
        when /\A(\d+)point(\d+)tb\z/ then "#{$1}.#{$2}TB"
        else capacity
        end
      end

      def format_screen_size(size)
        return nil if size.to_s.empty?

        number = size.to_f
        label = number == number.to_i ? number.to_i.to_s : number.to_s
        "#{label}-inch"
      end

      def format_chip_family(chip)
        normalized = Matcher.normalize_chip_family(chip)
        return nil unless normalized

        normalized.sub(/\Am(\d)/i, 'M\1')
                  .sub(/pro\z/i, " Pro")
                  .sub(/max\z/i, " Max")
                  .sub(/ultra\z/i, " Ultra")
      end

      def format_gb(gigabytes)
        gigabytes.to_i >= 1024 ? "#{gigabytes.to_i / 1024}TB" : "#{gigabytes}GB"
      end

      def format_price(price)
        return nil if price.to_s.empty?

        whole, cents = price.to_s.split(".")
        grouped = whole.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
        cents = cents.to_s.ljust(2, "0")[0, 2]
        cents == "00" ? "$#{grouped}" : "$#{grouped}.#{cents}"
      end

      def duration(seconds)
        seconds = seconds.to_i
        return "#{seconds}s" if seconds < 60

        minutes = seconds / 60
        return "#{minutes} min" if minutes < 60

        hours = minutes / 60
        minutes = minutes % 60
        return minutes.zero? ? "#{hours}h" : "#{hours}h #{minutes}m" if hours < 48

        "#{hours / 24} days"
      end

      def clock(time)
        time ? time.localtime.strftime("%H:%M:%S") : "?"
      end

      def clock_minute(time)
        time ? time.localtime.strftime("%H:%M") : "?"
      end

      def day(time)
        time ? time.localtime.strftime("%b %-d") : "?"
      end
  end
end
