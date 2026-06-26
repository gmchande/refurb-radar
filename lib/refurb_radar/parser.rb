# frozen_string_literal: true

module RefurbRadar
  class Parser
    GRID_ASSIGNMENT = "window.REFURB_GRID_BOOTSTRAP"

    def grid_from_html(html)
      JSON.parse(extract_assignment(html, GRID_ASSIGNMENT))
    rescue JSON::ParserError => error
      raise ParseError, "invalid REFURB_GRID_BOOTSTRAP JSON: #{error.message}"
    end

    def candidates_from_grid(grid, base_url)
      tiles = grid.fetch("tiles")
      tiles.map { |tile| candidate_from_tile(tile, base_url) }.compact
    rescue KeyError => error
      raise ParseError, "grid missing #{error.key}"
    end

    def candidate_from_pdp(html, url)
      product = json_ld_products(html).first || {}
      text = [
        product["name"],
        product["description"],
        meta_content(html, "og:title"),
        html
      ].compact.join(" ")

      part_number = product_sku(product) || html[/pdpAddToBag\/([^\/"'?#]+)/i, 1]
      title = product["name"] || meta_content(html, "og:title") || title_tag(html)
      model = model_key(text)
      memory = memory_key(text)
      capacity = capacity_key(text)

      return nil if [part_number, title, model, capacity].any? { |value| value.nil? || value == "" }
      return nil if memory_required?(model) && memory.to_s.empty?

      Candidate.new(
        part_number: part_number,
        title: title,
        url: url,
        model: model,
        memory: memory,
        capacity: capacity,
        price: product_price(product) || html[/"raw_amount"\s*:\s*"([^"]+)"/, 1],
        commit_string: html[/"customerCommitString"\s*:\s*"([^"]+)"/, 1],
        screen_size_inches: screen_size_inches(text),
        chip_family: chip_family_key(text)
      )
    end

    def catalog_candidates_from_pdp(html, source_url)
      selected = candidate_from_pdp(html, source_url)
      title = selected&.title || meta_content(html, "og:title") || title_tag(html)
      model = model_key([title, html].compact.join(" "))
      prices = variant_prices(html)
      variants = product_variations(html)

      candidates = variants.map do |part_number, variation|
        Candidate.new(
          part_number: part_number,
          title: variation["productTitle"] || title,
          url: source_url,
          model: model_key([variation["productTitle"], title].compact.join(" ")) || model,
          memory: variation["dimensionMemory"],
          capacity: variation["dimensionCapacity"],
          price: prices[part_number],
          commit_string: selected&.commit_string,
          screen_size_inches: screen_size_inches([variation["productTitle"], title].compact.join(" ")),
          chip_family: chip_family_key([variation["productTitle"], title].compact.join(" "))
        )
      end

      candidates << selected if selected
      candidates.uniq { |candidate| candidate.part_number }
    end

    def extract_assignment(html, assignment_name)
      bytes = html.b
      start = bytes.index(assignment_name)
      raise ParseError, "missing #{assignment_name}" unless start

      equals = bytes.index("=", start)
      raise ParseError, "missing assignment for #{assignment_name}" unless equals

      object_start = bytes.index("{", equals)
      raise ParseError, "missing object for #{assignment_name}" unless object_start

      object_end = find_balanced_object_end(bytes, object_start)
      bytes[object_start..object_end].force_encoding(Encoding::UTF_8)
    end

    private

    def candidate_from_tile(tile, base_url)
      dimensions = tile.dig("filters", "dimensions") || {}
      part_number = tile["partNumber"] || tile.dig("omnitureModel", "partNumber")
      title = tile["title"]
      relative_url = tile["productDetailsUrl"]
      model = model_key(title) || dimensions["refurbClearModel"]
      memory = dimensions["tsMemorySize"]
      capacity = dimensions["dimensionCapacity"]

      return nil if [part_number, title, relative_url, model, capacity].any? { |value| value.nil? || value == "" }
      return nil if memory_required?(model) && memory.to_s.empty?

      Candidate.new(
        part_number: part_number,
        title: title,
        url: URI.join(base_url, relative_url).to_s,
        model: model,
        memory: memory,
        capacity: capacity,
        price: tile.dig("price", "currentPrice", "raw_amount"),
        commit_string: tile.dig("omnitureModel", "customerCommitString"),
        screen_size_inches: screen_size_inches(title),
        chip_family: chip_family_key(title)
      )
    end

    def json_ld_products(html)
      html.scan(%r{<script[^>]+type=["']application/ld\+json["'][^>]*>(.*?)</script>}mi).flat_map do |match|
        collect_products(JSON.parse(match.first))
      rescue JSON::ParserError
        []
      end
    end

    def collect_products(value)
      case value
      when Array
        value.flat_map { |item| collect_products(item) }
      when Hash
        products = []
        type = Array(value["@type"])
        products << value if type.include?("Product")
        products.concat(collect_products(value["@graph"])) if value.key?("@graph")
        products
      else
        []
      end
    end

    def product_sku(product)
      return product["sku"] if product["sku"]

      offers(product).map { |offer| offer["sku"] }.compact.first
    end

    def product_price(product)
      offers(product).map { |offer| offer["price"] }.compact.first
    end

    def offers(product)
      value = product["offers"]
      return value if value.is_a?(Array)
      return [value] if value.is_a?(Hash)

      []
    end

    def product_variations(html)
      encoded = html[/"productVariationsPart"\s*:\s*"((?:\\.|[^"])*)"/m, 1]
      return {} unless encoded

      JSON.parse(JSON.parse(%("#{encoded}"))).fetch("productVariations", {})
    rescue JSON::ParserError, KeyError
      {}
    end

    def variant_prices(html)
      object = extract_json_object_after_key(html, "variantPrices")
      return {} unless object

      JSON.parse(object).fetch("items", []).each_with_object({}) do |item, prices|
        value = item["value"] || {}
        part_number = value["partNumber"]
        price = value.dig("price", "currentPrice", "raw_amount")
        prices[part_number] = price if part_number && price
      end
    rescue JSON::ParserError, KeyError
      {}
    end

    def extract_json_object_after_key(html, key)
      bytes = html.b
      start = bytes.index(%("#{key}"))
      return nil unless start

      colon = bytes.index(":", start)
      return nil unless colon

      object_start = bytes.index("{", colon)
      return nil unless object_start

      object_end = find_balanced_object_end(bytes, object_start)
      bytes[object_start..object_end].force_encoding(Encoding::UTF_8)
    end

    def meta_content(html, property)
      pattern = /<meta\b(?=[^>]*(?:property|name)=["']#{Regexp.escape(property)}["'])(?=[^>]*content=["']([^"']+)["'])[^>]*>/i
      html[pattern, 1]
    end

    def title_tag(html)
      html[%r{<title[^>]*>(.*?)</title>}mi, 1]&.strip
    end

    def model_key(text)
      normalized = text.downcase
      return "macstudio" if normalized.include?("mac studio")
      return "macmini" if normalized.include?("mac mini")
      return "macbookpro" if normalized.include?("macbook pro")
      return "macbookair" if normalized.include?("macbook air")
      return "macpro" if normalized.include?("mac pro")
      return "imac" if normalized.include?("imac")
      return "visionpro" if normalized.include?("vision pro")
    end

    def memory_key(text)
      match = text.match(/(\d+)\s*GB\s+unified\s+memory/i)
      "#{match[1].to_i}gb" if match
    end

    def capacity_key(text)
      if (match = text.match(/(\d+(?:\.\d+)?)\s*TB\s+SSD/i))
        decimal_to_key(match[1], "tb")
      elsif (match = text.match(/(\d+)\s*GB\s+SSD/i))
        "#{match[1].to_i}gb"
      elsif (match = text.match(/(\d+)\s*GB\s+storage/i))
        "#{match[1].to_i}gb"
      end
    end

    def memory_required?(model)
      model != "visionpro"
    end

    def screen_size_inches(text)
      match = text.to_s.match(/(\d+(?:\.\d+)?)\s*[- ]?\s*inch/i)
      return nil unless match

      value = match[1].to_f
      value == value.to_i ? value.to_i : value
    end

    def chip_family_key(text)
      match = text.to_s.match(/Apple\s+(M\d(?:\s+(?:Pro|Max|Ultra))?)\s+(?:chip|Chip)/i)
      return nil unless match

      match[1].downcase.gsub(/[^a-z0-9]/, "")
    end

    def decimal_to_key(value, unit)
      if value.include?(".")
        "#{value.sub(".", "point")}#{unit}"
      else
        "#{value.to_i}#{unit}"
      end
    end

    # Scans bytes, not characters: char indexing into a large multibyte UTF-8
    # page is O(n) per access in MRI, which made this loop quadratic (~16s on
    # the ~1MB grid page). The structural bytes are ASCII and never occur
    # inside UTF-8 multibyte sequences, so byte positions are safe.
    QUOTE_BYTE = '"'.ord
    BACKSLASH_BYTE = "\\".ord
    OPEN_BRACE_BYTE = "{".ord
    CLOSE_BRACE_BYTE = "}".ord

    def find_balanced_object_end(bytes, object_start)
      depth = 0
      in_string = false
      escape = false

      (object_start...bytes.bytesize).each do |index|
        byte = bytes.getbyte(index)

        if in_string
          if escape
            escape = false
          elsif byte == BACKSLASH_BYTE
            escape = true
          elsif byte == QUOTE_BYTE
            in_string = false
          end
          next
        end

        case byte
        when QUOTE_BYTE
          in_string = true
        when OPEN_BRACE_BYTE
          depth += 1
        when CLOSE_BRACE_BYTE
          depth -= 1
          return index if depth.zero?
        end
      end

      raise ParseError, "unterminated JSON object"
    end
  end
end
