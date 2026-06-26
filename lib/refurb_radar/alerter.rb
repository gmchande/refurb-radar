# frozen_string_literal: true

require "json"
require "net/http"
require "shellwords"
require "uri"

module RefurbRadar
  AlertReceipt = Struct.new(:channel, :success, :provider_id, :error, keyword_init: true) do
    def success?
      !!success
    end
  end

  AlertResult = Struct.new(:receipts, :suppressed_channels, keyword_init: true) do
    def self.from_boolean(value, channel:)
      new(receipts: [AlertReceipt.new(channel: channel, success: !!value)])
    end

    def success?
      receipts.any?(&:success?)
    end

    def suppressed_channels
      self[:suppressed_channels] || []
    end
  end

  class Alerter
    def self.from_env(env: ENV, err: $stderr)
      channels = []
      alert_command = RefurbRadar.env_value(env, "REFURB_RADAR_ALERT_COMMAND")
      channels << BrowserAlert.new(open_command: RefurbRadar.env_fetch(env, "REFURB_RADAR_OPEN_COMMAND", "/usr/bin/open"), err: err) if RefurbRadar.env_fetch(env, "REFURB_RADAR_BROWSER_ALERT", "1") != "0"
      channels << CommandAlert.new(command: alert_command, err: err) unless alert_command.to_s.strip.empty?

      twilio = TwilioClient.from_env(env: env)
      if twilio
        alert_to = RefurbRadar.env_value(env, "REFURB_RADAR_ALERT_TO")
        channels << TwilioSmsAlert.new(client: twilio, to: alert_to, err: err) if RefurbRadar.env_fetch(env, "REFURB_RADAR_TWILIO_SMS", "0") == "1"
        channels << TwilioCallAlert.new(client: twilio, to: alert_to, criteria: TwilioCallCriteria.from_env(env), err: err) if RefurbRadar.env_fetch(env, "REFURB_RADAR_TWILIO_CALL", "0") == "1"
      end

      new(channels: channels, err: err)
    end

    def initialize(channels: [BrowserAlert.new], err: $stderr)
      @channels = channels.compact
      @err = err
    end

    def alert(candidate)
      alert_with_receipts(candidate).success?
    end

    def alert_with_receipts(candidate, channels: nil, muted: [])
      if @channels.empty?
        @err.puts "warning=no_alert_channels_configured"
        return AlertResult.new(
          receipts: [AlertReceipt.new(channel: "none", success: false, error: "no_alert_channels_configured")]
        )
      end

      selected = channels ? @channels.select { |channel| channels.include?(channel_key(channel)) } : @channels
      if selected.empty? && @channels.any? { |channel| channel_key(channel) == channel_name(channel) }
        selected = @channels
      elsif selected.empty?
        return AlertResult.new(receipts: [])
      end

      delivered = selected.reject { |channel| muted.include?(channel_key(channel)) }
      suppressed = selected.select { |channel| muted.include?(channel_key(channel)) }

      AlertResult.new(
        receipts: delivered.map { |channel| receipt_for(channel, candidate) },
        suppressed_channels: suppressed.map { |channel| channel_key(channel) }
      )
    end

    def alerts_channel?(key)
      @channels.any? { |channel| channel_key(channel) == key }
    end

    private

    def receipt_for(channel, candidate)
      return channel.alert_with_receipt(candidate) if channel.respond_to?(:alert_with_receipt)

      AlertReceipt.new(channel: channel_name(channel), success: channel.alert(candidate))
    end

    def channel_name(channel)
      channel.class.name.split("::").last
    end

    def channel_key(channel)
      case channel
      when BrowserAlert
        "browser"
      when CommandAlert
        "command"
      when TwilioSmsAlert
        "twilio_sms"
      when TwilioCallAlert
        "twilio_call"
      else
        channel_name(channel)
      end
    end
  end

  class BrowserAlert
    def initialize(open_command: "/usr/bin/open", err: $stderr)
      @open_command = open_command
      @err = err
    end

    def alert(candidate)
      system(@open_command, candidate.url).tap do |opened|
        @err.puts "warning=open_failed url=#{candidate.url}" unless opened
      end
    end

    def alert_with_receipt(candidate)
      opened = alert(candidate)
      AlertReceipt.new(
        channel: "browser",
        success: opened,
        error: opened ? nil : "open_failed"
      )
    end
  end

  class CommandAlert
    def initialize(command: RefurbRadar.env_value(ENV, "REFURB_RADAR_ALERT_COMMAND"), err: $stderr)
      @command = command
      @err = err
    end

    def alert(candidate)
      return false if @command.nil? || @command.strip.empty?

      command = @command
        .gsub("{url}", Shellwords.escape(candidate.url))
        .gsub("{title}", Shellwords.escape(candidate.title))
        .gsub("{part_number}", Shellwords.escape(candidate.part_number))

      Process.detach(Process.spawn(command, out: File::NULL, err: File::NULL))
      true
    rescue SystemCallError => error
      @err.puts "warning=secondary_alert_failed #{error.message}"
      false
    end

    def alert_with_receipt(candidate)
      ok = alert(candidate)
      AlertReceipt.new(
        channel: "command",
        success: ok,
        error: ok ? nil : "command_failed"
      )
    end
  end

  class TwilioClient
    API_BASE = "https://api.twilio.com/2010-04-01"

    def self.from_env(env: ENV)
      account_sid = env["TWILIO_ACCOUNT_SID"]
      auth_token = env["TWILIO_AUTH_TOKEN"]
      from = env["TWILIO_FROM_NUMBER"]
      messaging_service_sid = env["TWILIO_MESSAGING_SERVICE_SID"]
      return nil if account_sid.to_s.empty? || auth_token.to_s.empty?

      new(
        account_sid: account_sid,
        auth_token: auth_token,
        from: from,
        messaging_service_sid: messaging_service_sid
      )
    end

    attr_reader :from, :messaging_service_sid

    def initialize(account_sid:, auth_token:, from: nil, messaging_service_sid: nil, http: Net::HTTP)
      @account_sid = account_sid
      @auth_token = auth_token
      @from = from
      @messaging_service_sid = messaging_service_sid
      @http = http
    end

    def send_sms(to:, body:)
      fields = { "To" => to, "Body" => body }
      if present?(@messaging_service_sid)
        fields["MessagingServiceSid"] = @messaging_service_sid
      else
        fields["From"] = @from
      end

      post_form("/Accounts/#{@account_sid}/Messages.json", fields)
    end

    def place_call(to:, twiml:)
      post_form(
        "/Accounts/#{@account_sid}/Calls.json",
        {
          "To" => to,
          "From" => @from,
          "Twiml" => twiml
        }
      )
    end

    private

    def post_form(path, fields)
      uri = URI("#{API_BASE}#{path}")
      request = Net::HTTP::Post.new(uri)
      request.basic_auth(@account_sid, @auth_token)
      request.set_form_data(fields)

      response = @http.start(uri.hostname, uri.port, use_ssl: true) do |connection|
        connection.request(request)
      end

      TwilioResponse.new(response)
    end

    def present?(value)
      !value.to_s.empty?
    end
  end

  class TwilioResponse
    def initialize(response)
      @response = response
    end

    def success?
      @response.code.to_i.between?(200, 299)
    end

    def sid
      parsed_body["sid"]
    end

    def error_message
      parsed_body["message"] || @response.message || "HTTP #{@response.code}"
    end

    private

    def parsed_body
      @parsed_body ||= JSON.parse(@response.body.to_s)
    rescue JSON::ParserError
      {}
    end
  end

  class TwilioSmsAlert
    def initialize(client:, to:, err: $stderr)
      @client = client
      @to = to
      @err = err
    end

    def alert(candidate)
      alert_with_receipt(candidate).success?
    end

    def alert_with_receipt(candidate)
      return missing_config!("sms") unless present?(@to)
      return missing_config!("sms from") unless present?(@client.from) || present?(@client.messaging_service_sid)

      response = @client.send_sms(to: @to, body: sms_body(candidate))
      if response.success?
        @err.puts "twilio_sms_sent sid=#{response.sid}"
        AlertReceipt.new(channel: "twilio_sms", success: true, provider_id: response.sid)
      else
        @err.puts "warning=twilio_sms_failed error=#{response.error_message.inspect}"
        AlertReceipt.new(channel: "twilio_sms", success: false, error: response.error_message)
      end
    rescue StandardError => error
      @err.puts "warning=twilio_sms_failed error=#{error.message.inspect}"
      AlertReceipt.new(channel: "twilio_sms", success: false, error: error.message)
    end

    private

    # Keep the whole body inside one GSM-7 SMS segment: long marketing URLs
    # and Apple's non-ASCII title hyphens (which force UCS-2 and 70-char
    # segments) made alerts multi-segment, which trial accounts reject
    # (Twilio 30044) and carriers filter.
    SMS_TITLE_LIMIT = 40

    def sms_body(candidate)
      [
        sms_prefix(candidate),
        candidate.part_number,
        sms_title(candidate),
        short_product_url(candidate)
      ].compact.join(" ")
    end

    def sms_prefix(candidate)
      case alert_kind(candidate)
      when "listing"
        "Apple refurb listed:"
      when "reminder"
        "Still buyable:"
      when "availability_signal"
        "Apple refurb availability signal:"
      else
        "Apple refurb buyable:"
      end
    end

    def sms_title(candidate)
      title = candidate.title.to_s
        .sub(/\ARefurbished\s+/i, "")
        .encode(Encoding::US_ASCII, invalid: :replace, undef: :replace, replace: "-")
      title.length > SMS_TITLE_LIMIT ? "#{title[0, SMS_TITLE_LIMIT - 1]}." : title
    end

    def short_product_url(candidate)
      part_number = candidate.part_number.to_s
      return candidate.url if part_number.empty?

      RefurbRadar.short_product_url(part_number)
    end

    def alert_kind(candidate)
      candidate.respond_to?(:alert_kind) ? candidate.alert_kind.to_s : ""
    end

    def missing_config!(label)
      @err.puts "warning=twilio_#{label.tr(" ", "_")}_missing"
      AlertReceipt.new(channel: "twilio_sms", success: false, error: "twilio_#{label.tr(" ", "_")}_missing")
    end

    def present?(value)
      !value.to_s.empty?
    end
  end

  class TwilioCallAlert
    def initialize(client:, to:, criteria: TwilioCallCriteria.new, err: $stderr)
      @client = client
      @to = to
      @criteria = criteria
      @err = err
    end

    def alert(candidate)
      alert_with_receipt(candidate).success?
    end

    def alert_with_receipt(candidate)
      return missing_config!("call") unless present?(@to)
      return missing_config!("call from") unless present?(@client.from)

      response = @client.place_call(to: @to, twiml: twiml(candidate))
      if response.success?
        @err.puts "twilio_call_started sid=#{response.sid}"
        AlertReceipt.new(channel: "twilio_call", success: true, provider_id: response.sid)
      else
        @err.puts "warning=twilio_call_failed error=#{response.error_message.inspect}"
        AlertReceipt.new(channel: "twilio_call", success: false, error: response.error_message)
      end
    rescue StandardError => error
      @err.puts "warning=twilio_call_failed error=#{error.message.inspect}"
      AlertReceipt.new(channel: "twilio_call", success: false, error: error.message)
    end

    private

    def twiml(candidate)
      escaped_title = candidate.title.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      <<~XML.strip
        <Response><Say voice="alice">Apple refurbished alert. #{candidate.part_number}. #{escaped_title}. Check your text message for the buy link.</Say></Response>
      XML
    end

    def missing_config!(label)
      @err.puts "warning=twilio_#{label.tr(" ", "_")}_missing"
      AlertReceipt.new(channel: "twilio_call", success: false, error: "twilio_#{label.tr(" ", "_")}_missing")
    end

    def present?(value)
      !value.to_s.empty?
    end

  end

  class TwilioCallCriteria
    def self.from_env(env)
      new(
        models: RefurbRadar.env_value(env, "REFURB_RADAR_TWILIO_CALL_MODELS"),
        min_memory_gb: integer_or_nil(RefurbRadar.env_value(env, "REFURB_RADAR_TWILIO_CALL_MIN_MEMORY_GB")),
        min_cpu_cores: integer_or_nil(RefurbRadar.env_value(env, "REFURB_RADAR_TWILIO_CALL_MIN_CPU_CORES")),
        max_capacity_gb: integer_or_nil(RefurbRadar.env_value(env, "REFURB_RADAR_TWILIO_CALL_MAX_CAPACITY_GB"))
      )
    end

    def self.integer_or_nil(value)
      return nil if value.to_s.strip.empty?

      Integer(value)
    end

    def initialize(models: nil, min_memory_gb: nil, min_cpu_cores: nil, max_capacity_gb: nil)
      @models = normalize_models(models)
      @min_memory_gb = min_memory_gb
      @min_cpu_cores = min_cpu_cores
      @max_capacity_gb = max_capacity_gb
    end

    def matches?(candidate)
      return false unless @models.empty? || @models.include?(candidate.model)
      return false if @min_memory_gb && (!memory_gb(candidate.memory) || memory_gb(candidate.memory) < @min_memory_gb)
      return false if @min_cpu_cores && (!cpu_cores(candidate) || cpu_cores(candidate) < @min_cpu_cores)
      return false if @max_capacity_gb && (!capacity_gb(candidate.capacity) || capacity_gb(candidate.capacity) > @max_capacity_gb)

      true
    end

    private

    def normalize_models(value)
      Array(value).flat_map { |item| item.to_s.split(/[,\s]+/) }
                  .map { |model| model.downcase.gsub(/[^a-z0-9]/, "") }
                  .reject(&:empty?)
    end

    def memory_gb(value)
      match = value.to_s.match(/\A(\d+)gb\z/)
      match[1].to_i if match
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

    def cpu_cores(candidate)
      # Apple's titles use a non-breaking hyphen (U+2011) in "14‑Core CPU".
      match = candidate.title.to_s.match(/(\d+)[\p{Pd}\s]+core\s+cpu/i)
      if match
        match[1].to_i
      else
        Matcher.chip_cpu_core_floor(candidate.chip_family)
      end
    end
  end
end
