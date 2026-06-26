# frozen_string_literal: true

require "fileutils"
require "json"

module RefurbRadar
  class EventLog
    DEFAULT_MAX_EVENTS = 20_000
    DURABLE_TYPES = %w[
      alert_attempt
      alert_suppressed
      buyability_flip
      confirming_recheck
      listing_event
      reminder_event
    ].freeze

    def initialize(path, max_events: DEFAULT_MAX_EVENTS)
      @path = path
      @max_events = max_events
      @line_count = nil
    end

    def append_many(events)
      return if events.empty?

      FileUtils.mkdir_p(File.dirname(@path))
      new_lines = events.map { |event| utf8(JSON.generate(event)) }
      if appendable?(new_lines.length)
        append_lines(new_lines)
      else
        rewrite_retained_lines(new_lines)
      end
    end

    def read
      return [] unless File.exist?(@path)

      existing_lines.filter_map do |line|
        next if line.strip.empty?

        JSON.parse(line)
      end
    rescue JSON::ParserError => error
      raise ParseError, "invalid event log #{@path}: #{error.message}"
    end

    # Cheap newest-events read for the status page: seeks the file tail instead
    # of parsing the whole log, and skips lines that fail to parse rather than
    # raising, since a live page must render through a torn write.
    def tail(limit = 50)
      return [] if limit < 1 || !File.exist?(@path)

      size = File.size(@path)
      # Line sizes vary too much for a fixed bytes-per-line estimate (local
      # verdict events carry ~700-byte URLs), so grow the chunk until it
      # actually holds `limit` lines or the whole file.
      chunk = [size, limit * 512].min
      lines = []
      loop do
        raw = File.open(@path, "rb") do |file|
          file.seek(size - chunk)
          file.read
        end
        lines = raw.force_encoding(Encoding::UTF_8).scrub("?").lines(chomp: true)
        lines.shift if chunk < size
        break if chunk == size || lines.length >= limit

        chunk = [chunk * 2, size].min
      end
      lines.last(limit).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    private
      def appendable?(new_line_count)
        @line_count ||= existing_line_count
        @line_count + new_line_count <= compaction_threshold
      end

      def append_lines(new_lines)
        File.open(@path, "a:UTF-8") do |file|
          new_lines.each { |line| file.puts(line) }
        end
        @line_count += new_lines.length
      end

      def rewrite_retained_lines(new_lines)
        retained = retained_lines(existing_lines + new_lines)
        tmp_path = "#{@path}.tmp-#{$$}-#{Thread.current.object_id}"
        begin
          File.write(tmp_path, retained.join("\n") + "\n", mode: "w:UTF-8")
          File.rename(tmp_path, @path)
        ensure
          File.unlink(tmp_path) if File.exist?(tmp_path)
        end
        @line_count = retained.length
      end

      def retained_lines(lines)
        return [] if @max_events < 1

        keep = {}
        durable_count = 0
        durable_limit = durable_retention_limit
        recent_start = [lines.length - (@max_events - durable_limit), 0].max

        (recent_start...lines.length).each { |index| keep[index] = true }
        (recent_start - 1).downto(0) do |index|
          if durable_line?(lines[index])
            keep[index] = true
            durable_count += 1
          end
          break if durable_count >= durable_limit || keep.length >= @max_events
        end
        (lines.length - 1).downto(0) do |index|
          break if keep.length >= @max_events

          keep[index] = true
        end

        keep.keys.sort.map { |index| lines[index] }
      end

      def durable_line?(line)
        event = JSON.parse(line)
        DURABLE_TYPES.include?(event["type"])
      rescue JSON::ParserError
        false
      end

      def durable_retention_limit
        return 0 if @max_events < 2

        [[@max_events / 5, 1].max, 1_000, @max_events - 1].min
      end

      # Apple titles carry non-ASCII characters (U+2011 hyphens). Under launchd
      # no LANG is set, so the default external encoding is US-ASCII and an
      # encoding-naive read/write crashes mid-pass. Read and tag explicitly.
      def existing_lines
        return [] unless File.exist?(@path)

        File.readlines(@path, chomp: true, mode: "r:UTF-8").map { |line| utf8(line) }
      end

      def existing_line_count
        return 0 unless File.exist?(@path)

        File.foreach(@path, mode: "r:UTF-8").count
      end

      def compaction_threshold
        if @max_events < 1_000
          @max_events
        else
          @max_events + [@max_events / 4, 1_000].max
        end
      end

      def utf8(string)
        string.dup.force_encoding(Encoding::UTF_8).scrub("?")
      end
  end

  class NullEventLog
    def append_many(_events); end

    def read
      []
    end

    def tail(_limit = 50)
      []
    end
  end
end
