# frozen_string_literal: true

require "json"

module RefurbRadar
  class ProductMatrix
    DEFAULT_PATH = File.expand_path("../../config/product_matrix.json", __dir__)

    def self.default
      @default ||= new
    end

    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    def choices(models:, chip_family: nil)
      rows = rows_for(models: models, chip_family: chip_family)
      {
        memory: values(rows, "memory_gb"),
        cores: values(rows, "cpu_cores"),
        capacity: values(rows, "capacity_gb"),
        chip: rows.map { |row| row["chip_family"] }.compact.uniq.sort
      }
    end

    private
      attr_reader :path

      def rows_for(models:, chip_family: nil)
        normalized_models = Matcher.normalize_models(models)
        normalized_chip = Matcher.normalize_chip_family(chip_family)
        normalized_models.flat_map do |model|
          data.fetch("models", {}).fetch(model, [])
        end.select do |row|
          normalized_chip.nil? || Matcher.normalize_chip_family(row["chip_family"]) == normalized_chip
        end
      end

      def data
        @data ||= JSON.parse(File.read(path, mode: "r:UTF-8"))
      rescue Errno::ENOENT, JSON::ParserError, EncodingError
        { "models" => {} }
      end

      def values(rows, key)
        rows.flat_map { |row| Array(row[key]) }.compact.uniq.sort
      end
  end
end
