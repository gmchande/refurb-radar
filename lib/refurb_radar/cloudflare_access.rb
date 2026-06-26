# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module RefurbRadar
  class CloudflareAccess
    CERT_CACHE_TTL = 300

    attr_reader :env

    def initialize(env: ENV)
      @env = env
    end

    def enabled?
      team_domain != "" || audience != ""
    end

    def valid_request?(headers)
      if !enabled?
        true
      elsif team_domain == "" || audience == ""
        false
      else
        token = access_token(headers)
        if token == ""
          false
        else
          payload = verify(token)
          payload && issuer_valid?(payload) && audience_valid?(payload) && time_valid?(payload)
        end
      end
    end

    private
      def team_domain = env.fetch("CLOUDFLARE_ACCESS_TEAM_DOMAIN", "").to_s
      def audience = env.fetch("CLOUDFLARE_ACCESS_AUD", "").to_s

      def access_token(headers)
        header(headers, "Cf-Access-Jwt-Assertion") || header(headers, "HTTP_CF_ACCESS_JWT_ASSERTION") || ""
      end

      def header(headers, name)
        headers.each do |key, value|
          if key.to_s.downcase == name.downcase
            return Array(value).first.to_s
          end
        end
        nil
      end

      def verify(token)
        encoded_header, encoded_payload, encoded_signature = token.split(".", 3)
        if encoded_header.to_s.empty? || encoded_payload.to_s.empty? || encoded_signature.to_s.empty?
          nil
        else
          header = JSON.parse(decode_segment(encoded_header))
          if header.fetch("alg", "") == "RS256"
            key = public_key(header.fetch("kid", ""))
            if key && valid_signature?(key, encoded_header, encoded_payload, encoded_signature)
              JSON.parse(decode_segment(encoded_payload))
            end
          end
        end
      rescue JSON::ParserError, KeyError, ArgumentError, OpenSSL::OpenSSLError
        nil
      end

      def valid_signature?(key, encoded_header, encoded_payload, encoded_signature)
        signature = decode_segment(encoded_signature)
        signed = "#{encoded_header}.#{encoded_payload}"
        key.verify(OpenSSL::Digest::SHA256.new, signature, signed)
      end

      def public_key(kid)
        cert = certs.fetch(kid, nil)
        cert ? OpenSSL::X509::Certificate.new(cert).public_key : nil
      end

      def certs
        cache = self.class.instance_variable_get(:@cert_cache)
        if cache && Time.now < cache.fetch(:expires_at)
          cache.fetch(:certs)
        else
          fetched = fetch_certs
          unless fetched.empty?
            self.class.instance_variable_set(
              :@cert_cache,
              { certs: fetched, expires_at: Time.now + CERT_CACHE_TTL }
            )
          end
          fetched
        end
      rescue JSON::ParserError, KeyError, Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError
        {}
      end

      def fetch_certs
        uri = URI("https://#{team_domain}/cdn-cgi/access/certs")
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 2, read_timeout: 2) do |http|
          http.get(uri.request_uri)
        end
        data = JSON.parse(response.body)
        Array(data.fetch("public_certs")).to_h { |entry| [entry.fetch("kid"), entry.fetch("cert")] }
      rescue JSON::ParserError, KeyError, Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError
        {}
      end

      def issuer_valid?(payload)
        payload.fetch("iss", "") == "https://#{team_domain}"
      end

      def audience_valid?(payload)
        Array(payload.fetch("aud", [])).include?(audience)
      end

      def time_valid?(payload)
        now = Time.now.to_i
        exp = payload.fetch("exp", 0).to_i
        nbf = payload.fetch("nbf", 0).to_i
        exp > now && (nbf.zero? || nbf <= now)
      end

      def decode_segment(segment)
        padded = segment.to_s.tr("-_", "+/")
        padded += "=" * ((4 - padded.length % 4) % 4)
        padded.unpack1("m0")
      end
  end
end
