# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module RefurbRadar
  # Pause/resume state for outbound alert channels, shared between the watcher
  # worker (reads it every pass) and the status web process (writes it). Stored
  # as small JSON in the same state volume as seen.json.
  #
  # Reads fail open: a missing or corrupt control file means "nothing paused",
  # so a broken file can never silently mute a safety-net alerter. Pauses are
  # timed by default and auto-resume once paused_until passes.
  class ControlStore
    CHANNELS = %w[twilio_sms twilio_call browser].freeze
    INDEFINITE = "indefinite"

    EMPTY_CONTROLS = { "channels" => {} }.freeze

    def initialize(path, now: -> { Time.now.utc })
      @path = path
      @now = now
    end

    def muted_channels
      snapshot = load
      now = @now.call
      CHANNELS.select { |channel| muted?(snapshot, channel, now) }
    end

    def status
      snapshot = load
      now = @now.call
      CHANNELS.to_h do |channel|
        until_value = snapshot.dig("channels", channel, "paused_until")
        [channel, { "paused" => muted?(snapshot, channel, now), "paused_until" => until_value }]
      end
    end

    def pause(channel, paused_until:)
      raise ArgumentError, "unknown channel #{channel}" unless CHANNELS.include?(channel)

      data = load
      (data["channels"] ||= {})[channel] = { "paused_until" => normalize(paused_until) }
      save(data)
    end

    def resume(channel)
      raise ArgumentError, "unknown channel #{channel}" unless CHANNELS.include?(channel)

      data = load
      data.fetch("channels", {}).delete(channel)
      save(data)
    end

    def load
      return Marshal.load(Marshal.dump(EMPTY_CONTROLS)) unless File.exist?(@path)

      JSON.parse(File.read(@path, mode: "r:UTF-8"))
    rescue JSON::ParserError, EncodingError
      Marshal.load(Marshal.dump(EMPTY_CONTROLS))
    end

    private
      def muted?(snapshot, channel, now)
        until_value = snapshot.dig("channels", channel, "paused_until")
        if until_value.nil?
          false
        elsif until_value == INDEFINITE
          true
        else
          Time.parse(until_value).utc > now
        end
      rescue ArgumentError
        false
      end

      def normalize(paused_until)
        case paused_until
        when INDEFINITE, :indefinite
          INDEFINITE
        when Time
          paused_until.utc.iso8601
        else
          paused_until.to_s
        end
      end

      def save(data)
        FileUtils.mkdir_p(File.dirname(@path))
        tmp_path = "#{@path}.tmp"
        File.write(tmp_path, JSON.pretty_generate(data) + "\n", mode: "w:UTF-8")
        File.rename(tmp_path, @path)
      end
  end
end
