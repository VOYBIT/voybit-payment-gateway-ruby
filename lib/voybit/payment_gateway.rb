# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module Voybit
  module PaymentGateway
    DEFAULT_BASE_URL = "https://api.voybit.com/api/v1"
    USER_AGENT = "voybit-payment-gateway-ruby/0.2.0"
    IDEMPOTENCY = /\A[A-Za-z0-9][A-Za-z0-9._:-]{7,127}\z/
    POSITIVE_DECIMAL = /\A(?:0|[1-9]\d*)(?:\.\d+)?\z/
    FIAT_CURRENCY = /\A[A-Z]{3}\z/
    RETRYABLE = [408, 429, 500, 502, 503, 504].freeze
    TOLERANCE_SECONDS = 300

    class Error < StandardError
      attr_reader :status, :code, :request_id, :retry_after

      def initialize(status, code, message, request_id = "", retry_after = 0)
        super(message.to_s.empty? ? "payment gateway returned HTTP #{status}" : message.to_s)
        @status = status
        @code = code.to_s.empty? ? "unknown_error" : code.to_s
        @request_id = request_id.to_s
        @retry_after = retry_after.to_i
      end
    end

    class Client
      def initialize(api_key:, base_url: DEFAULT_BASE_URL)
        raise ArgumentError, "API key is required" if api_key.to_s.empty?

        @api_key = api_key
        @base_url = base_url.to_s.sub(%r{/+\z}, "")
      end

      def create_payment(request, idempotency_key)
        create_resource("/gateway/payments", request, idempotency_key, "payment")
      end

      def create_checkout_session(request, idempotency_key)
        fields = stringify(request)
        amount = fields["fiat_amount"]
        currency = fields["fiat_currency"]
        unless amount.is_a?(String) && amount.match?(POSITIVE_DECIMAL) && amount.match?(/[1-9]/)
          raise ArgumentError, "fiat_amount must be a positive decimal string"
        end
        unless currency.is_a?(String) && currency.match?(FIAT_CURRENCY)
          raise ArgumentError, "fiat_currency must be a three-letter uppercase currency code"
        end
        window = fields["payment_window_seconds"]
        if !window.nil? && (!window.is_a?(Integer) || window <= 0)
          raise ArgumentError, "payment_window_seconds must be a positive integer"
        end
        description = fields["description"]
        raise ArgumentError, "description must be a string" if !description.nil? && !description.is_a?(String)

        metadata = fields["metadata"]
        raise ArgumentError, "metadata must be an object" if !metadata.nil? && !metadata.is_a?(Hash)

        body = {
          "fiat_amount" => amount,
          "fiat_currency" => currency
        }
        body["description"] = description unless description.nil?
        body["metadata"] = metadata unless metadata.nil?
        body["payment_window_seconds"] = window unless window.nil?
        create_resource("/gateway/checkout-sessions", body, idempotency_key, "checkout_session")
      end

      def self.verify_webhook(secret:, id:, timestamp:, signature:, raw_body:, now: Time.now)
        hex = signature.is_a?(String) && signature.start_with?("v1=") ? signature[3..] : ""
        unless !secret.to_s.empty? && !id.to_s.empty? && timestamp.to_s.match?(/\A\d+\z/) && hex.match?(/\A[0-9a-fA-F]{64}\z/)
          raise ArgumentError, "webhook signature is invalid"
        end
        if (now.to_i - timestamp.to_i).abs > TOLERANCE_SECONDS
          raise ArgumentError, "webhook timestamp is outside the 5 minute window"
        end

        supplied = [hex].pack("H*")
        signed = +"#{id}.#{timestamp}.".b
        signed << raw_body.to_s.b
        expected = OpenSSL::HMAC.digest("SHA256", secret, signed)
        return if secure_compare(expected, supplied)

        raise ArgumentError, "webhook signature does not match"
      end

      def self.secure_compare(expected, supplied)
        return false unless expected.bytesize == supplied.bytesize

        difference = 0
        expected.bytes.zip(supplied.bytes) { |left, right| difference |= left ^ right }
        difference.zero?
      end
      private_class_method :secure_compare

      def self.parse_event(raw_body)
        event = JSON.parse(raw_body)
        raise ArgumentError, "webhook body must be an object" unless event.is_a?(Hash)

        event
      end

      private

      def create_resource(path, request, idempotency_key, result_key)
        unless idempotency_key.to_s.match?(IDEMPOTENCY)
          raise ArgumentError, "Idempotency-Key must be 8 to 128 URL-safe characters"
        end

        body = JSON.generate(stringify(request))
        endpoint = URI("#{@base_url}#{path}")
        last_error = nil
        4.times do |attempt|
          begin
            return post(endpoint, body, idempotency_key, result_key)
          rescue Error => error
            raise if !RETRYABLE.include?(error.status) || attempt == 3

            last_error = error
            sleep delay(attempt, error.retry_after)
          rescue IOError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, OpenSSL::SSL::SSLError => error
            raise if attempt == 3

            last_error = error
            sleep delay(attempt, 0)
          end
        end
        raise last_error || Error.new(0, "unknown_error", "payment gateway request failed")
      end

      def post(endpoint, body, idempotency_key, result_key)
        request = Net::HTTP::Post.new(endpoint)
        request["X-Voybit-Api-Key"] = @api_key
        request["Idempotency-Key"] = idempotency_key
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request["User-Agent"] = USER_AGENT
        request.body = body

        http = Net::HTTP.new(endpoint.host, endpoint.port)
        http.use_ssl = endpoint.scheme == "https"
        http.open_timeout = 20
        http.read_timeout = 20
        http.write_timeout = 20 if http.respond_to?(:write_timeout=)
        http.max_retries = 0 if http.respond_to?(:max_retries=)
        response = http.request(request)
        decoded = decode(response.body.to_s, response.code.to_i)
        request_id = response["X-Request-ID"].to_s
        status = response.code.to_i
        if status >= 200 && status < 300
          return {
            result_key => decoded,
            "replayed" => response["Idempotency-Replayed"] == "true",
            "request_id" => request_id
          }
        end

        error = decoded["error"].is_a?(Hash) ? decoded["error"] : {}
        retry_after = response["Retry-After"].to_i
        raise Error.new(status, error["code"].to_s, error["message"].to_s, request_id, retry_after)
      end

      def decode(body, status)
        return {} if body.empty?

        parsed = JSON.parse(body)
        raise Error.new(status, "invalid_response", "response was not JSON") unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        raise Error.new(status, "invalid_response", "response was not JSON") if status >= 200 && status < 300

        {}
      end

      def stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), out| out[key.to_s] = stringify(item) }
        when Array
          value.map { |item| stringify(item) }
        else
          value
        end
      end

      def delay(attempt, retry_after)
        return [retry_after, 30].min if retry_after.positive?

        [0.5 * (2**attempt), 8].min
      end
    end
  end
end
