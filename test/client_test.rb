# frozen_string_literal: true

require "json"
require "socket"
require "voybit/payment_gateway"

def check(condition, message)
  raise message unless condition
end

def serve(status, reason, body)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.addr[1]
  seen = {}
  thread = Thread.new do
    client = server.accept
    data = +""
    data << client.readpartial(4096) while data !~ /\r\n\r\n/
    head, rest = data.split("\r\n\r\n", 2)
    length = head[/Content-Length: (\d+)/i, 1].to_i
    rest = +"" if rest.nil?
    rest << client.readpartial(length - rest.bytesize) while rest.bytesize < length
    seen["body"] = rest.byteslice(0, length)
    seen["key"] = head[/X-Voybit-Api-Key: (.+)\r/, 1]
    seen["idempotency"] = head[/Idempotency-Key: (.+)\r/, 1]
    payload = body
    headers = [
      "HTTP/1.1 #{status} #{reason}",
      "Content-Type: application/json",
      "Content-Length: #{payload.bytesize}",
      "Connection: close"
    ]
    client.write("#{headers.join("\r\n")}\r\n\r\n#{payload}")
    client.close
  ensure
    server.close
  end
  [port, thread, seen]
end

port, thread, seen = serve(201, "Created", '{"id":"pay_1","status":"pending","checkout_url":"https://voybit.com/pay/pub_1","amount_minor":2500}')
client = Voybit::PaymentGateway::Client.new(api_key: "vb_test_example_secret", base_url: "http://127.0.0.1:#{port}/api/v1")
created = client.create_payment({ asset_id: "asset", crypto_amount: "25.0000", amount_minor: 2500, fiat_currency: "USD" }, "order:1001:attempt:1")
thread.join
check(created["payment"]["checkout_url"] == "https://voybit.com/pay/pub_1", "checkout")
check(seen["key"] == "vb_test_example_secret", "api key")
check(seen["idempotency"] == "order:1001:attempt:1", "idempotency")
check(JSON.parse(seen["body"])["amount_minor"] == 2500, "amount")

port, thread, seen = serve(201, "Created", '{"session_id":"7155d76a-9f81-40eb-9233-878aac50eb20","public_id":"nYVvXxsYGr5LZk8Dn7hU0Q","status":"open","checkout_url":"https://voybit.com/pay/nYVvXxsYGr5LZk8Dn7hU0Q","fiat_amount":"25","fiat_currency":"USD"}')
client = Voybit::PaymentGateway::Client.new(api_key: "vb_test_example_secret", base_url: "http://127.0.0.1:#{port}/api/v1")
created = client.create_checkout_session(
  {
    fiat_amount: "25.00",
    fiat_currency: "USD",
    description: "Order 1001",
    metadata: { order_id: "1001" },
    payment_window_seconds: 1800,
    asset_id: "must-not-be-sent"
  },
  "order:1001:attempt:1"
)
thread.join
sent_body = JSON.parse(seen["body"])
check(created["checkout_session"]["status"] == "open", "checkout session")
check(!sent_body.key?("asset_id"), "buyer chooses asset")
check(sent_body["fiat_amount"] == "25.00", "checkout fiat amount")

port, thread, = serve(422, "Unprocessable Entity", '{"error":{"code":"asset_unavailable","message":"That asset is not enabled for this gateway."}}')
begin
  Voybit::PaymentGateway::Client.new(api_key: "vb_test_example_secret", base_url: "http://127.0.0.1:#{port}/api/v1").create_payment(
    { asset_id: "asset" },
    "order:1001:attempt:1"
  )
  raise "validation error was not raised"
rescue Voybit::PaymentGateway::Error => error
  thread.join
  check(error.code == "asset_unavailable", "code")
end

raw = '{"type":"payment.paid","status":"paid"}'
now = Time.at(1_700_000_000)
timestamp = "1700000000"
signature = "v1=" + OpenSSL::HMAC.hexdigest("SHA256", "whsec_example", "delivery-1.#{timestamp}.#{raw}")
Voybit::PaymentGateway::Client.verify_webhook(secret: "whsec_example", id: "delivery-1", timestamp: timestamp, signature: signature, raw_body: raw, now: now)
check(Voybit::PaymentGateway::Client.parse_event(raw)["status"] == "paid", "status")
begin
  Voybit::PaymentGateway::Client.verify_webhook(secret: "whsec_example", id: "delivery-1", timestamp: timestamp, signature: signature, raw_body: "#{raw} ", now: now)
  raise "tampered body was accepted"
rescue ArgumentError => error
  check(error.message.include?("does not match"), "tamper")
end

puts "ruby ok"
