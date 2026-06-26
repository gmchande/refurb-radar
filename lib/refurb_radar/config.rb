# frozen_string_literal: true

module RefurbRadar
  module Config
    DEFAULT_WATCH_URLS_PATH = File.expand_path("../../config/watch_urls.txt", __dir__)
    DEFAULT_SKU_SEED_PATH = File.expand_path("../../config/sku_seed.json", __dir__)

    module_function

    def seed_urls(env: ENV, path: DEFAULT_WATCH_URLS_PATH)
      urls = []
      urls.concat(RefurbRadar.env_fetch(env, "REFURB_RADAR_WATCH_URLS", "").split(/[,\s]+/))
      urls.concat(file_urls(path))
      urls.map(&:strip).reject(&:empty?).uniq
    end

    def watch_urls(env: ENV, path: DEFAULT_WATCH_URLS_PATH, catalog_path: DEFAULT_CATALOG_PATH, seed_path: DEFAULT_SKU_SEED_PATH, matcher: Matcher.from_env(env: env))
      seeds = seed_urls(env: env, path: path)
      seed_catalog = catalog_urls(seed_path, matcher: matcher)
      catalog = catalog_urls(catalog_path, matcher: matcher)
      catalog_parts = (seed_catalog + catalog).filter_map { |url| product_part_number(url) }
      filtered_seeds = seeds.reject do |url|
        part_number = product_part_number(url)
        part_number && catalog_parts.include?(part_number)
      end

      (filtered_seeds + seed_catalog + catalog).uniq
    end

    def watch_candidates(env: ENV, catalog_path: DEFAULT_CATALOG_PATH, seed_path: DEFAULT_SKU_SEED_PATH, matcher: Matcher.from_env(env: env))
      products = CatalogStore.new(seed_path).products + CatalogStore.new(catalog_path).products
      products.filter_map do |product|
        next unless active_product?(product)

        candidate = candidate_from_product(product)
        candidate if matcher.eligible?(candidate)
      end.uniq(&:part_number)
    rescue Error
      []
    end

    def catalog_urls(path = DEFAULT_CATALOG_PATH, matcher: Matcher.new)
      CatalogStore.new(path).products.filter_map do |product|
        next unless active_product?(product)

        candidate = candidate_from_product(product)
        next unless matcher.eligible?(candidate)

        product["url"] || RefurbRadar.short_product_url(product.fetch("part_number"))
      end
    rescue Error
      []
    end

    def candidate_from_product(product)
      Candidate.new(
        part_number: product.fetch("part_number"),
        title: product["title"],
        url: product["url"] || RefurbRadar.short_product_url(product.fetch("part_number")),
        model: product["model"],
        memory: product["memory"],
        capacity: product["capacity"],
        price: product["price"],
        screen_size_inches: product["screen_size_inches"] || screen_size_inches(product["title"]),
        chip_family: product["chip_family"] || chip_family_key(product["title"])
      )
    end

    def active_product?(product)
      product["retired_at"].to_s.empty?
    end

    def screen_size_inches(text)
      match = text.to_s.match(/(\d+(?:\.\d+)?)\s*[- ]?\s*inch/i)
      return nil unless match

      value = match[1].to_f
      value == value.to_i ? value.to_i : value
    end

    def chip_family_key(text)
      match = text.to_s.match(/Apple\s+(M\d(?:\s+(?:Pro|Max|Ultra))?)\s+chip/i)
      return nil unless match

      Matcher.normalize_chip_family(match[1])
    end

    def file_urls(path)
      return [] unless File.exist?(path)

      File.readlines(path, chomp: true).map do |line|
        line.sub(/#.*/, "").strip
      end.reject(&:empty?)
    end

    def product_part_number(url)
      match = url.match(%r{/shop/product/([^/?#]+)/([^/?#]+)})
      return nil unless match

      "#{match[1]}/#{match[2]}".upcase
    end
  end
end
