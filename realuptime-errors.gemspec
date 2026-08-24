# frozen_string_literal: true

require_relative "lib/realuptime/errors/version"

Gem::Specification.new do |spec|
  spec.name = "realuptime-errors"
  spec.version = Realuptime::Errors::SDK_VERSION
  spec.authors = ["RealUptime"]
  spec.email = ["support@realuptime.io"]
  spec.summary = "Zero-dependency error tracking SDK for Ruby, Rails, Rack and Sidekiq (RealUptime Errors)."
  spec.description = "Captures exceptions with scrub-by-default PII handling, bounded buffering with honest drop " \
                     "counters, and framework integrations for Rails, Rack and Sidekiq. Standard library only."
  spec.homepage = "https://realuptime.io/error-tracking"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6"
  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/RealUptimeHQ/realuptime-errors-ruby",
    "bug_tracker_uri" => "https://github.com/RealUptimeHQ/realuptime-errors-ruby/issues",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir["lib/**/*.rb"] + %w[scrub-vectors.json README.md LICENSE]
  spec.require_paths = ["lib"]
  # Zero runtime dependencies, enforced by test/wire_contract_test.rb.
end
