# frozen_string_literal: true

require "json"

module RefurbRadar
  class Matcher
    Rule = Struct.new(
      :models,
      :min_memory_gb,
      :max_memory_gb,
      :max_capacity_gb,
      :min_cpu_cores,
      :max_price,
      :screen_size_inches,
      :chip_family,
      keyword_init: true
    )
    DEFAULT_RULES_PATH = File.expand_path("../../config/targets.json", __dir__)
    CHIP_CPU_CORE_FLOORS = {
      "m2" => 8,
      "m2pro" => 10,
      "m4" => 10,
      "m4pro" => 12,
      "m1max" => 10,
      "m1ultra" => 20,
      "m2max" => 12,
      "m2ultra" => 24,
      "m3ultra" => 28,
      "m3max" => 14,
      "m4max" => 14
    }.freeze

    def self.from_env(env: ENV, path: nil)
      new(
        rules: rules_from_file(path || RefurbRadar.env_fetch(env, "REFURB_RADAR_TARGETS", DEFAULT_RULES_PATH)),
        extra_models: RefurbRadar.env_fetch(env, "REFURB_RADAR_EXTRA_MODELS", "")
      )
    end

    # One rule per model is the canonical shape (the page edits rules
    # per-product), so a hand-written multi-model rule splits into one rule
    # per model with the same constraints.
    def self.rules_from_file(path)
      raw = JSON.parse(File.read(path, mode: "r:UTF-8"))
      Array(raw.fetch("rules")).flat_map do |rule|
        normalize_models(rule.fetch("models")).map do |model|
          Rule.new(
            models: [model],
            min_memory_gb: rule.key?("min_memory_gb") ? Integer(rule["min_memory_gb"]) : nil,
            max_memory_gb: rule.key?("max_memory_gb") ? Integer(rule["max_memory_gb"]) : nil,
            max_capacity_gb: rule.key?("max_capacity_gb") ? Integer(rule["max_capacity_gb"]) : nil,
            min_cpu_cores: rule.key?("min_cpu_cores") ? Integer(rule["min_cpu_cores"]) : nil,
            max_price: rule.key?("max_price") ? Integer(rule["max_price"]) : nil,
            screen_size_inches: rule.key?("screen_size_inches") ? normalize_screen_size(rule["screen_size_inches"]) : nil,
            chip_family: rule.key?("chip_family") ? normalize_chip_family(rule["chip_family"]) : nil
          )
        end
      end
    rescue Errno::ENOENT, JSON::ParserError, KeyError, ArgumentError, TypeError => error
      raise ParseError, "invalid target rules #{path}: #{error.message}"
    end

    def self.normalize_models(value)
      Array(value).flat_map { |item| item.to_s.split(/[,\s]+/) }
                  .map { |model| model.downcase.gsub(/[^a-z0-9]/, "") }
                  .reject(&:empty?)
    end

    def self.normalize_chip_family(value)
      value.to_s.downcase.gsub(/[^a-z0-9]/, "").then { |chip| chip.empty? ? nil : chip }
    end

    def self.chip_cpu_core_floor(value)
      CHIP_CPU_CORE_FLOORS[normalize_chip_family(value)]
    end

    def self.numeric(value)
      number = Float(value)
      number == number.to_i ? number.to_i : number
    end

    def self.normalize_screen_size(value)
      return nil if value.to_s.empty?

      numeric(value)
    rescue ArgumentError, TypeError
      nil
    end

    attr_reader :rules

    def initialize(rules: self.class.rules_from_file(DEFAULT_RULES_PATH), extra_models: [])
      @rules = rules.map do |rule|
        Rule.new(
          models: rule.models.dup,
          min_memory_gb: rule.min_memory_gb,
          max_memory_gb: rule.max_memory_gb,
          max_capacity_gb: rule.max_capacity_gb,
          min_cpu_cores: rule.min_cpu_cores,
          max_price: rule.max_price,
          screen_size_inches: rule.screen_size_inches,
          chip_family: rule.chip_family
        )
      end
      extra = self.class.normalize_models(extra_models)
      @rules.each { |rule| rule.models.concat(extra).uniq! } unless extra.empty?
    end

    def target_model?(candidate)
      @rules.any? { |rule| rule.models.include?(candidate.model) }
    end

    def eligible?(candidate)
      !matching_rule(candidate).nil?
    end

    def matching_rule(candidate)
      @rules.find { |rule| shortfalls(candidate, rule).empty? }
    end

    # The constraints this candidate fails, so callers can tell a match
    # (empty), a near miss (one), and a clear miss apart.
    def shortfalls(candidate, rule)
      return [:model] unless rule.models.include?(candidate.model)

      failed = []
      if rule.min_memory_gb
        memory = memory_gb(candidate.memory)
        failed << :memory unless memory && memory >= rule.min_memory_gb
      end
      if rule.max_memory_gb
        memory = memory_gb(candidate.memory)
        failed << :memory unless failed.include?(:memory) || memory && memory <= rule.max_memory_gb
      end
      if rule.min_cpu_cores
        cores = candidate_cpu_cores(candidate)
        failed << :cores unless cores && cores >= rule.min_cpu_cores
      end
      if rule.max_capacity_gb
        capacity = capacity_gb(candidate.capacity)
        failed << :capacity unless capacity && capacity <= rule.max_capacity_gb
      end
      if rule.max_price
        price = price_dollars(candidate.price)
        failed << :price unless price && price <= rule.max_price
      end
      if rule.screen_size_inches
        failed << :screen_size unless self.class.normalize_screen_size(candidate.screen_size_inches) == rule.screen_size_inches
      end
      if rule.chip_family
        failed << :chip unless self.class.normalize_chip_family(candidate.chip_family) == rule.chip_family
      end
      failed
    end

    def memory_gb(value)
      match = value.to_s.match(/\A(\d+)gb\z/)
      return nil unless match

      match[1].to_i
    end

    def capacity_gb(value)
      case value.to_s
      when /\A(\d+)gb\z/
        Regexp.last_match(1).to_i
      when /\A(\d+)tb\z/
        Regexp.last_match(1).to_i * 1024
      when /\A(\d+)point(\d+)tb\z/
        whole = Regexp.last_match(1).to_i
        decimal = "0.#{Regexp.last_match(2)}".to_f
        ((whole + decimal) * 1024).round
      end
    end

    # Apple writes "14‑Core CPU" with a non-breaking hyphen (U+2011), so the
    # dash class must cover all dash punctuation, not just ASCII "-".
    def cpu_cores(title)
      match = title.to_s.match(/(\d+)[\p{Pd}\s]+core\s+cpu/i)
      match && match[1].to_i
    end

    def candidate_cpu_cores(candidate)
      cpu_cores(candidate.title) || self.class.chip_cpu_core_floor(candidate.chip_family)
    end

    def price_dollars(value)
      Float(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
