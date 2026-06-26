# frozen_string_literal: true

require "fileutils"
require "json"

module RefurbRadar
  # The hunt rules file, shared between the watcher worker (re-reads it every
  # pass via Matcher) and the status web process (edits it from the page).
  # Rules are plain hashes in file order; file order is priority order, so a
  # product is grouped under the first rule that matches it.
  class TargetsStore
    CONSTRAINTS = %w[min_memory_gb max_memory_gb min_cpu_cores max_capacity_gb max_price screen_size_inches chip_family].freeze

    def initialize(path)
      @path = path
    end

    def rules
      load.fetch("rules", [])
    end

    def add(model)
      normalized = Matcher.normalize_models(model)
      raise ArgumentError, "blank model" if normalized.empty?

      data = load
      data["rules"] = data.fetch("rules", []) + [{ "models" => normalized }]
      save(data)
    end

    def update(index, constraints)
      data = load
      rule = rule_at(data, index)
      CONSTRAINTS.each do |key|
        value = constraints[key]
        if value.nil?
          rule.delete(key)
        elsif key == "chip_family"
          rule[key] = Matcher.normalize_chip_family(value)
        elsif key == "screen_size_inches"
          rule[key] = Matcher.numeric(value)
        else
          rule[key] = Integer(value)
        end
      end
      save(data)
    end

    def remove(index)
      data = load
      rule_at(data, index)
      data.fetch("rules").delete_at(Integer(index))
      save(data)
    end

    def load
      return { "rules" => [] } unless File.exist?(@path)

      data = JSON.parse(File.read(@path, mode: "r:UTF-8"))
      # One rule per model is canonical (the page edits rules per product, and
      # rule indexes must agree with the Matcher's view), so multi-model rules
      # split on read and persist split on the next save.
      data["rules"] = Array(data["rules"]).flat_map do |rule|
        Matcher.normalize_models(rule["models"]).map { |model| rule.merge("models" => [model]) }
      end
      data
    rescue JSON::ParserError, EncodingError
      { "rules" => [] }
    end

    private
      def rule_at(data, index)
        position = Integer(index)
        raise ArgumentError, "no rule at #{index}" if position.negative?

        data.fetch("rules", [])[position] or raise ArgumentError, "no rule at #{index}"
      end

      def save(data)
        FileUtils.mkdir_p(File.dirname(@path))
        tmp_path = "#{@path}.tmp"
        File.write(tmp_path, JSON.pretty_generate(data) + "\n", mode: "w:UTF-8")
        File.rename(tmp_path, @path)
      end
  end
end
