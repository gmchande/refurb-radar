# frozen_string_literal: true

require "fileutils"

module RefurbRadar
  class CatalogStore
    EMPTY_CATALOG = {
      "updated_at" => nil,
      "products" => []
    }.freeze

    def initialize(path)
      @path = path
    end

    def load
      return Marshal.load(Marshal.dump(EMPTY_CATALOG)) unless File.exist?(@path)

      JSON.parse(File.read(@path, mode: "r:UTF-8"))
    rescue JSON::ParserError, EncodingError => error
      raise ParseError, "invalid catalog JSON #{@path}: #{error.message}"
    end

    def urls
      products.map { |product| product["url"] || RefurbRadar.short_product_url(product.fetch("part_number")) }.compact
    end

    def products
      load.fetch("products", [])
    end

    def save(catalog)
      FileUtils.mkdir_p(File.dirname(@path))
      tmp_path = "#{@path}.tmp"
      File.write(tmp_path, JSON.pretty_generate(catalog) + "\n", mode: "w:UTF-8")
      File.rename(tmp_path, @path)
    end

    def update
      FileUtils.mkdir_p(File.dirname(@path))
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        catalog = yield load
        save(catalog) if catalog
        catalog
      end
    end
  end

  class CatalogRefresh
    Result = Struct.new(:checked_at, :catalog, :discovered_candidates, :warnings, keyword_init: true)

    def initialize(
      grid_url: DEFAULT_GRID_URL,
      seed_urls: [],
      fetcher: Fetcher.new,
      parser: Parser.new,
      matcher: Matcher.new,
      store: CatalogStore.new(DEFAULT_CATALOG_PATH),
      now: -> { Time.now.utc }
    )
      @grid_url = grid_url
      @seed_urls = seed_urls.uniq
      @fetcher = fetcher
      @parser = parser
      @matcher = matcher
      @store = store
      @now = now
    end

    def run
      checked_at = @now.call
      warnings = []
      candidates = []

      begin
        grid_html = @fetcher.get(@grid_url)
        grid = @parser.grid_from_html(grid_html)
        candidates.concat(@parser.candidates_from_grid(grid, @grid_url))
      rescue Error => error
        warnings << "grid_unconfirmed error=#{error.message.inspect}"
      end

      @seed_urls.each do |url|
        html = @fetcher.get(url)
        candidates.concat(@parser.catalog_candidates_from_pdp(html, url))
      rescue Error => error
        warnings << "seed_unconfirmed url=#{url.inspect} error=#{error.message.inspect}"
      end

      discovered = candidates.compact
      catalog = @store.update do |previous_catalog|
        merge_catalog(previous_catalog, discovered, checked_at)
      end

      Result.new(
        checked_at: checked_at,
        catalog: catalog,
        discovered_candidates: discovered,
        warnings: warnings
      )
    end

    private

    def merge_catalog(previous_catalog, candidates, checked_at)
      checked_at_iso = checked_at.iso8601
      previous_by_part = previous_catalog.fetch("products", []).to_h { |product| [product.fetch("part_number"), product] }
      merged_by_part = previous_by_part.transform_values(&:dup)

      candidates.each do |candidate|
        previous = merged_by_part[candidate.part_number] || {}
        merged_by_part[candidate.part_number] = product_record(candidate, previous, checked_at_iso)
      end

      {
        "updated_at" => checked_at_iso,
        "products" => merged_by_part.values.sort_by { |product| product.fetch("part_number") }
      }
    end

    def product_record(candidate, previous, checked_at_iso)
      {
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
        "first_discovered_at" => previous["first_discovered_at"] || checked_at_iso,
        "last_seen_at" => checked_at_iso
      }.compact
    end
  end

  def self.short_product_url(part_number)
    "https://www.apple.com/ca/shop/product/#{part_number.upcase}"
  end
end
