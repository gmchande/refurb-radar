# frozen_string_literal: true

require "fileutils"
require "time"

module RefurbRadar
  class StateStore
    DEFAULT_REMINDER_INTERVAL_SECONDS = 300
    DEFAULT_CALL_INTERVAL_SECONDS = 600
    AVAILABILITY_STABLE_PASSES = 20
    AVAILABILITY_COOLDOWN_SECONDS = 3600
    LISTING_STABLE_ABSENT_PASSES = 20

    EMPTY_STATE = {
      "last_checked_at" => nil,
      "stats" => {
        "successful_checks" => 0,
        "total_alerts" => 0,
        "last_check" => {}
      },
      "currently_seen" => {},
      "history" => []
    }.freeze

    def initialize(path)
      @path = path
    end

    def load
      return Marshal.load(Marshal.dump(EMPTY_STATE)) unless File.exist?(@path)

      JSON.parse(File.read(@path, mode: "r:UTF-8"))
    rescue JSON::ParserError, EncodingError => error
      raise ParseError, "invalid state JSON #{@path}: #{error.message}"
    end

    def save(state)
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate(state) + "\n", mode: "w:UTF-8")
    end

    def alertable_candidates(
      state:,
      visible_candidates:,
      buyable_candidates:,
      checked_at:,
      listed_candidates: [],
      availability_signal_candidates: [],
      not_buyable_candidates: [],
      unconfirmed_part_numbers: [],
      check_summary: {},
      reminder_interval_seconds: DEFAULT_REMINDER_INTERVAL_SECONDS,
      call_interval_seconds: DEFAULT_CALL_INTERVAL_SECONDS,
      confirm_calls: false,
      listing_surface_checked: true
    )
      checked_at_iso = checked_at.iso8601
      previous_seen = state.fetch("currently_seen", {})
      visible_by_part = visible_candidates.to_h { |candidate| [candidate.part_number, candidate] }
      listed_by_part = listed_candidates.to_h { |candidate| [candidate.part_number, candidate] }
      buyable_by_part = buyable_candidates.to_h { |candidate| [candidate.part_number, candidate] }
      availability_signal_by_part = availability_signal_candidates.to_h { |candidate| [candidate.part_number, candidate] }
      not_buyable_by_part = not_buyable_candidates.to_h { |candidate| [candidate.part_number, candidate] }
      next_seen = {}
      alerts = []

      visible_by_part.each do |part_number, candidate|
        previous = previous_seen[part_number]
        record = previous ? previous.dup : initial_record(candidate, checked_at_iso)
        record["title"] = candidate.title
        record["url"] = candidate.url
        record["last_seen_at"] = checked_at_iso
        record["first_detected_at"] ||= checked_at_iso

        if listing_surface_checked
          if listed_by_part.key?(part_number)
            record_first_surface(record, "grid", checked_at_iso)
            if listing_alertable?(record, checked_at)
              alerts << candidate_with_alert_kind(listed_by_part.fetch(part_number), "listing")
            end
            record["listed_present"] = true
            record["last_listed_at"] = checked_at_iso
            record["not_listed_streak"] = 0
          else
            record["listed_present"] = false
            record["not_listed_streak"] = record.fetch("not_listed_streak", 0).to_i + 1
            if listing_absent_stable?(record)
              record.delete("listing_alerted_at")
              clear_first_surface(record, "grid")
            end
            record["last_not_listed_at"] = checked_at_iso if previous
          end
        end

        if buyable_by_part.key?(part_number)
          record_first_surface(record, "buyability", checked_at_iso)
          if continuing_buyable_episode?(previous)
            # First confirming pass calls; thereafter re-ring on its own cadence
            # while the part stays buyable, so a missed call keeps trying.
            if confirm_calls && call_due?(previous, checked_at, call_interval_seconds)
              alerts << candidate_with_alert_kind(buyable_by_part.fetch(part_number), "confirmed_buyable_call") unless retry_delayed?(record, checked_at)
            end
            if reminder_due?(previous, checked_at, reminder_interval_seconds)
              alerts << candidate_with_alert_kind(buyable_by_part.fetch(part_number), "reminder") unless retry_delayed?(record, checked_at)
            end
          else
            alerts << buyable_by_part.fetch(part_number) unless retry_delayed?(record, checked_at)
            record["pending_call_at"] = checked_at_iso
          end
          record["last_buyable_at"] = checked_at_iso
          record["not_available_streak"] = 0
          record.delete("last_not_buyable_at")
        elsif availability_signal_by_part.key?(part_number)
          record_first_surface(record, "availability_signal", checked_at_iso)
          if availability_alertable?(record, checked_at)
            alerts << candidate_with_alert_kind(availability_signal_by_part.fetch(part_number), "availability_signal")
          end
          record["last_availability_signal_at"] = checked_at_iso
          record["not_available_streak"] = 0
          record.delete("last_not_buyable_at")
        elsif not_buyable_by_part.key?(part_number)
          record["not_available_streak"] = record.fetch("not_available_streak", 0).to_i + 1
          record.delete("last_buyable_at")
          record.delete("last_availability_signal_at")
          if not_buyable_stable?(record)
            record.delete("alerted_at")
            record.delete("buyable_alerted_at")
            record.delete("confirmed_buyable_call_alerted_at")
            record.delete("pending_call_at")
            record.delete("reminder_alerted_at")
            record.delete("alert_failures")
            record.delete("next_alert_attempt_at")
            clear_first_surface(record, "buyability")
            clear_first_surface(record, "availability_signal")
          end
          record["last_not_buyable_at"] = checked_at_iso
        end

        next_seen[part_number] = record
      end

      unconfirmed_part_numbers.each do |part_number|
        next if next_seen.key?(part_number)
        next unless previous_seen.key?(part_number)

        record = previous_seen.fetch(part_number).dup
        record["last_unconfirmed_at"] = checked_at_iso
        next_seen[part_number] = record
      end

      disappeared = previous_seen.keys - next_seen.keys
      disappeared.each do |part_number|
        record = previous_seen[part_number].dup
        record["disappeared_at"] = checked_at_iso
        state["history"] << record
      end

      state["last_checked_at"] = checked_at_iso
      state["currently_seen"] = next_seen
      record_successful_check(state, checked_at_iso, check_summary)
      alerts
    end

    def mark_alerted(state, candidate, alerted_at:)
      record = state.fetch("currently_seen").fetch(candidate.part_number)
      record["alerted_at"] = alerted_at.iso8601
      record["#{alert_kind(candidate)}_alerted_at"] = alerted_at.iso8601
      record["last_reminder_at"] = alerted_at.iso8601 if alert_kind(candidate) == "reminder"
      record.delete("alert_failures")
      record.delete("next_alert_attempt_at")
      stats = state["stats"] ||= {}
      stats["total_alerts"] = stats.fetch("total_alerts", 0).to_i + 1
      stats["last_alerted_at"] = alerted_at.iso8601
    end

    def record_alert_attempt(state, candidate, receipts, attempted_at:)
      record = state.fetch("currently_seen").fetch(candidate.part_number)
      attempts = record["alert_attempts"] ||= []
      receipts.each do |receipt|
        attempts << {
          "attempted_at" => attempted_at.iso8601,
          "channel" => receipt.channel,
          "success" => receipt.success?,
          "provider_id" => receipt.provider_id,
          "error" => receipt.error
        }.compact
      end
      record["alert_attempts"] = attempts.last(20)

      if receipts.any?(&:success?)
        mark_alerted(state, candidate, alerted_at: attempted_at)
      elsif alert_kind(candidate) == "buyable"
        mark_buyable_attempted(record, attempted_at: attempted_at)
      else
        failures = record.fetch("alert_failures", 0).to_i + 1
        delay = [30, 60, 120, 300, 600][[failures - 1, 4].min]
        record["alert_failures"] = failures
        record["next_alert_attempt_at"] = (attempted_at + delay).iso8601
      end
    end

    private

    def record_successful_check(state, checked_at_iso, check_summary)
      stats = state["stats"] ||= {}
      stats["successful_checks"] = stats.fetch("successful_checks", 0).to_i + 1
      stats["last_check"] = check_summary.merge("checked_at" => checked_at_iso)
    end

    def mark_buyable_attempted(record, attempted_at:)
      record["buyable_alerted_at"] ||= attempted_at.iso8601
      record.delete("alert_failures")
      record.delete("next_alert_attempt_at")
    end

    def initial_record(candidate, checked_at_iso)
      {
        "part_number" => candidate.part_number,
        "title" => candidate.title,
        "url" => candidate.url,
        "first_seen_at" => checked_at_iso
      }
    end

    def record_first_surface(record, source, checked_at_iso)
      record["first_positive_source"] ||= source
      record["first_positive_at"] ||= checked_at_iso
      record[first_surface_field(source)] ||= checked_at_iso
    end

    def clear_first_surface(record, source)
      record.delete(first_surface_field(source))
      refresh_first_positive(record)
    end

    def refresh_first_positive(record)
      first = first_surface_entries(record).min_by { |_source, checked_at_iso| checked_at_iso }

      if first
        record["first_positive_source"] = first.first
        record["first_positive_at"] = first.last
      else
        record.delete("first_positive_source")
        record.delete("first_positive_at")
      end
    end

    def first_surface_entries(record)
      first_surface_sources.filter_map do |source|
        field = first_surface_field(source)
        [source, record[field]] if record[field]
      end
    end

    def first_surface_sources
      %w[buyability grid availability_signal]
    end

    def first_surface_field(source)
      case source
      when "buyability"
        "first_buyability_true_at"
      when "grid"
        "first_grid_present_at"
      else
        "first_availability_signal_at"
      end
    end

    def retry_delayed?(record, checked_at)
      value = record["next_alert_attempt_at"]
      return false if value.to_s.empty?

      Time.parse(value).utc > checked_at
    rescue ArgumentError
      false
    end

    def listing_alertable?(record, checked_at)
      if retry_delayed?(record, checked_at)
        false
      else
        !record["listed_present"] && record["listing_alerted_at"].to_s.empty?
      end
    end

    def listing_absent_stable?(record)
      record.fetch("not_listed_streak", 0).to_i >= LISTING_STABLE_ABSENT_PASSES
    end

    def alert_kind(candidate)
      value = candidate.alert_kind if candidate.respond_to?(:alert_kind)
      value.to_s.empty? ? "buyable" : value
    end

    def continuing_buyable_episode?(record)
      record && record["buyable_alerted_at"] && !not_buyable_stable?(record)
    end

    def not_buyable_stable?(record)
      record.fetch("not_available_streak", 0).to_i >= AVAILABILITY_STABLE_PASSES
    end

    def reminder_due?(record, checked_at, interval)
      return false unless interval&.positive?
      return false unless record["buyable_alerted_at"]

      last = record["last_reminder_at"] || record["buyable_alerted_at"]
      Time.parse(last).utc + interval <= checked_at
    rescue ArgumentError
      true
    end

    def call_due?(record, checked_at, interval)
      return false unless record["pending_call_at"]

      last_call = record["confirmed_buyable_call_alerted_at"]
      return true if last_call.to_s.empty?
      return false unless interval&.positive?

      Time.parse(last_call).utc + interval <= checked_at
    rescue ArgumentError
      true
    end

    def availability_alertable?(record, checked_at)
      return false if retry_delayed?(record, checked_at)
      return false if record.fetch("not_available_streak", 0).to_i < AVAILABILITY_STABLE_PASSES

      last_alerted = record["availability_signal_alerted_at"]
      last_alerted.to_s.empty? || Time.parse(last_alerted).utc + AVAILABILITY_COOLDOWN_SECONDS <= checked_at
    rescue ArgumentError
      true
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
  end
end
