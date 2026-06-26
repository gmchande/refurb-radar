# frozen_string_literal: true

module RefurbRadar
  class BuyabilityMessages
    def parse(body)
      parsed = JSON.parse(body.to_s)
      message = parsed.dig("body", "content", "buyabilityMessage")
      raise ParseError, "missing buyabilityMessage" unless message.is_a?(Hash)

      buckets = message.fetch("order").flat_map do |bucket|
        products = message.fetch(bucket)
        raise ParseError, "invalid buyability bucket #{bucket}" unless products.is_a?(Hash)

        products.map do |part_number, value|
          raise ParseError, "missing isBuyable for #{part_number}" unless value.is_a?(Hash) && value.key?("isBuyable")

          [part_number.upcase, value.fetch("isBuyable") == true]
        end
      end

      buckets.to_h
    rescue JSON::ParserError, KeyError, TypeError => error
      raise ParseError, "invalid buyability message JSON: #{error.message}"
    end
  end

  class BuyabilityEndpoint
    def initialize(base_url:)
      @base_url = base_url
    end

    def url_for(part_numbers)
      uri = URI(@base_url)
      existing = URI.decode_www_form(uri.query.to_s)
      generated = part_numbers.each_with_index.flat_map do |part_number, index|
        [
          ["parts.#{index}", part_number],
          ["mts.#{index}", "regular"]
        ]
      end
      uri.query = URI.encode_www_form(existing + generated + [["little", "true"]])
      uri.to_s
    end
  end

  class BuyabilityClient
    Result = Struct.new(:flags, :metadata, keyword_init: true)

    def initialize(
      endpoint: BuyabilityEndpoint.new(base_url: DEFAULT_BUYABILITY_URL),
      fetcher: Fetcher.new,
      parser: BuyabilityMessages.new
    )
      @endpoint = endpoint
      @fetcher = fetcher
      @parser = parser
    end

    def fetch(part_numbers)
      return Result.new(flags: {}, metadata: {}) if part_numbers.empty?

      response = if @fetcher.respond_to?(:get_with_metadata)
        @fetcher.get_with_metadata(@endpoint.url_for(part_numbers))
      else
        FetchResult.new(body: @fetcher.get(@endpoint.url_for(part_numbers)), headers: {}, code: "200")
      end

      Result.new(
        flags: @parser.parse(response.body),
        metadata: response_metadata(response)
      )
    end

    private

    def response_metadata(response)
      {
        "code" => response.code,
        "server_timing" => response.headers["server-timing"],
        "cache_control" => response.headers["cache-control"],
        "x_cache" => response.headers["x-cache"],
        "duration_seconds" => response.duration_seconds&.round(3)
      }.compact
    end
  end

  class Buyability
    Verdict = Struct.new(:positive_signals, :negative_signals, keyword_init: true) do
      def buyable?
        positive_signals.any? && negative_signals.empty?
      end

      def availability_signal?
        positive_signals.any? && !buyable?
      end

      def reason
        "positive=#{positive_signals.join(",").inspect} negative=#{negative_signals.join(",").inspect}"
      end

      def ambiguous?
        positive_signals.empty? && negative_signals.empty?
      end
    end

    def confirm(html)
      positive = []
      negative = []

      positive << "schema_in_stock" if html.include?("schema.org/InStock")
      negative << "schema_out_of_stock" if html.include?("schema.org/OutOfStock")
      positive << "is_buyable_true" if html.match?(/"isBuyable"\s*:\s*true/)
      negative << "is_buyable_false" if html.match?(/"isBuyable"\s*:\s*false/)
      positive << "buyable_true" if html.match?(/"buyable"\s*:\s*true/)
      negative << "buyable_false" if html.match?(/"buyable"\s*:\s*false/)
      positive << "buy_button_enabled" if html.match?(/"buyNowButton"\s*:\s*\{[^{}]*"disabled"\s*:\s*false/m)
      negative << "buy_button_disabled" if html.match?(/"buyNowButton"\s*:\s*\{[^{}]*"disabled"\s*:\s*true/m)
      positive << "add_to_cart_enabled" if add_to_cart_enabled?(html)
      negative << "add_to_cart_disabled" if add_to_cart_disabled?(html)
      negative << "commit_out_of_stock" if html.match?(/"customerCommitString"\s*:\s*"Out of stock"/i)

      Verdict.new(positive_signals: positive.uniq, negative_signals: negative.uniq)
    end

    private

    def add_to_cart_enabled?(html)
      html.match?(/<button\b(?=[^>]*data-autom="add-to-cart")(?![^>]*disabled\b)[^>]*>/m)
    end

    def add_to_cart_disabled?(html)
      html.match?(/<button\b(?=[^>]*data-autom="add-to-cart")(?=[^>]*disabled\b)[^>]*>/m)
    end
  end
end
