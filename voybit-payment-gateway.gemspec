# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "voybit-payment-gateway"
  spec.version = "0.2.0"
  spec.summary = "Create buyer-choice Voybit checkout sessions and verify webhooks."
  spec.authors = ["Voybit"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/VOYBIT/voybit-payment-gateway-ruby"
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
end
