# frozen_string_literal: true

require "net/http"
require "time"
require "uri"

module RefurbRadar
  FetchResult = Struct.new(:body, :headers, :code, :duration_seconds, :url, keyword_init: true) do
    def rejected?
      %w[403 429 541].include?(code.to_s) || code.to_i.between?(500, 599)
    end
  end

  class Fetcher
    MAX_REDIRECTS = 5
    MAX_BACKOFF_SECONDS = 60
    DEFAULT_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
    RETRYABLE_CODES = (["429"] + (500..599).map(&:to_s) + ["403"]).freeze

    def initialize(open_timeout: 10, read_timeout: 15, user_agent: DEFAULT_USER_AGENT, sleeper: Kernel, now: -> { Time.now.utc }, http: Net::HTTP)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @user_agent = user_agent
      @sleeper = sleeper
      @now = now
      @http = http
      @backoff_by_host = {}
      @backoff_mutex = Mutex.new
      @connections = {}
      @connection_mutex = Mutex.new
    end

    def get(url, redirect_limit: MAX_REDIRECTS, headers: {})
      get_with_metadata(url, redirect_limit: redirect_limit, headers: headers).body
    end

    def get_with_metadata(url, redirect_limit: MAX_REDIRECTS, headers: {})
      raise FetchError, "too many redirects for #{url}" if redirect_limit.negative?

      uri = URI(url)
      wait_for_backoff(uri.host)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = request(uri, headers: headers)
      duration_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      case response
      when Net::HTTPSuccess
        clear_backoff(uri.host)
        FetchResult.new(
          body: response.body.to_s.dup.force_encoding(Encoding::UTF_8),
          headers: response_headers(response),
          code: response.code,
          duration_seconds: duration_seconds,
          url: url
        )
      when Net::HTTPRedirection
        location = response["location"]
        raise FetchError, "redirect missing location for #{url}" if location.nil? || location.empty?

        get_with_metadata(URI.join(uri, location).to_s, redirect_limit: redirect_limit - 1, headers: headers)
      else
        record_backoff(uri.host, response.code) if RETRYABLE_CODES.include?(response.code)
        raise FetchError, "GET #{url} failed with HTTP #{response.code}"
      end
    rescue URI::InvalidURIError => error
      raise FetchError, "invalid URL #{url.inspect}: #{error.message}"
    rescue IOError, SystemCallError, SocketError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => error
      raise FetchError, "GET #{url} failed: #{error.message}"
    rescue defined?(Socket::ResolutionError) ? Socket::ResolutionError : SocketError => error
      raise FetchError, "GET #{url} failed: #{error.message}"
    end

    private

    def request(uri, headers: {})
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = @user_agent
      request["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
      request["Accept-Language"] = "en-CA,en-US;q=0.9,en;q=0.8"
      request["Cache-Control"] = "no-cache"
      request["Pragma"] = "no-cache"
      headers.each { |key, value| request[key] = value }
      connection_for(uri).request(request)
    rescue IOError, EOFError
      reset_connection(uri)
      connection_for(uri).request(request)
    end

    def connection_for(uri)
      key = [uri.scheme, uri.host, uri.port]
      @connection_mutex.synchronize do
        connection = @connections[key]
        return connection if connection && (!connection.respond_to?(:started?) || connection.started?)

        @connections[key] = @http.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: @open_timeout,
          read_timeout: @read_timeout
        )
      end
    end

    def reset_connection(uri)
      key = [uri.scheme, uri.host, uri.port]
      @connection_mutex.synchronize do
        connection = @connections.delete(key)
        connection.finish if connection&.respond_to?(:finish) && connection.started?
      end
    end

    def response_headers(response)
      response.each_header.each_with_object({}) do |(key, value), headers|
        headers[key.downcase] = value
      end
    end

    def wait_for_backoff(host)
      state = @backoff_mutex.synchronize { @backoff_by_host[host]&.dup }
      return unless state

      delay = state[:until] - @now.call
      @sleeper.sleep(delay) if delay.positive?
    end

    def record_backoff(host, code)
      @backoff_mutex.synchronize do
        state = @backoff_by_host[host] || { failures: 0, until: @now.call }
        failures = state[:failures] + 1
        delay = [2**failures, MAX_BACKOFF_SECONDS].min
        @backoff_by_host[host] = {
          failures: failures,
          until: @now.call + delay,
          code: code
        }
      end
    end

    def clear_backoff(host)
      @backoff_mutex.synchronize do
        @backoff_by_host.delete(host)
      end
    end
  end

  class StoreSession
    SESSION_TTL_SECONDS = 900

    def initialize(grid_url: DEFAULT_GRID_URL, fetcher: Fetcher.new, now: -> { Time.now.utc })
      @grid_url = grid_url
      @fetcher = fetcher
      @now = now
      @cookie_header = nil
      @refreshed_at = nil
    end

    def get(url)
      get_with_metadata(url).body
    end

    def get_with_metadata(url)
      request_with_session(url)
    rescue FetchError
      refresh
      request(url)
    end

    def refresh
      response = request(@grid_url)
      remember_session(response)
      response
    end

    private

    def request_with_session(url)
      if expired?
        if url == @grid_url
          response = request(url)
          remember_session(response)
          return response unless response.rejected?
        else
          refresh
        end
      end
      response = request(url)
      if response.rejected?
        refresh
        request(url)
      else
        response
      end
    end

    def expired?
      @refreshed_at.nil? || @now.call - @refreshed_at >= SESSION_TTL_SECONDS
    end

    def request(url)
      if @fetcher.respond_to?(:get_with_metadata)
        begin
          @fetcher.get_with_metadata(url, headers: session_headers)
        rescue ArgumentError
          @fetcher.get_with_metadata(url)
        end
      else
        FetchResult.new(body: @fetcher.get(url), headers: {}, code: "200", url: url)
      end
    end

    def remember_session(response)
      @refreshed_at = @now.call
      cookies = response.headers.fetch("set-cookie", "").split(/,\s*(?=[^;,]+=)/).map { |cookie| cookie.split(";", 2).first }
      @cookie_header = cookies.reject(&:empty?).join("; ") unless cookies.empty?
    end

    def session_headers
      return {} if @cookie_header.to_s.empty?

      { "Cookie" => @cookie_header }
    end
  end
end
