# frozen_string_literal: true

require_relative "test_helper"
require "realuptime/errors/rails"

# Exercises the Rails integration WITHOUT Rails installed: the helpers are
# plain Ruby, the Railtie is defined only when ::Rails::Railtie exists, and
# the ActiveJob extension is driven through a stand-in base class that
# exposes around_perform the way ActiveJob::Base does.
class RailsIntegrationTest < Minitest::Test
  include SdkTestSupport

  def test_requiring_the_file_outside_rails_defines_no_railtie
    refute defined?(::Rails::Railtie), "this suite assumes Rails is not loaded"
    refute Realuptime::Errors::Rails.const_defined?(:Railtie)
  end

  def test_request_context_adds_the_controller_action_as_the_route_template
    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/orders/42",
            "action_dispatch.request.path_parameters" => { controller: "orders", action: "show", id: "42" } }
    assert_equal({ "method" => "GET", "path" => "/orders/42", "route" => "orders#show" },
                 Realuptime::Errors::Rails.request_context(env))
  end

  def test_middleware_reports_with_the_framework_tag_and_route
    setup_sdk
    app = ->(_env) { raise NameError, "undefined local variable" }
    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/orders/42",
            "action_dispatch.request.path_parameters" => { "controller" => "orders", "action" => "show" } }
    assert_raises(NameError) { Realuptime::Errors::Rails::RailsMiddleware.new(app).call(env) }
    event = @server.events.fetch(0)
    assert_equal({ "method" => "GET", "path" => "/orders/42", "route" => "orders#show" }, event["request"])
    assert_equal({ "framework" => "rails" }, event["tags"])
  end

  def test_middleware_catches_the_exception_rails_rendered_itself
    setup_sdk
    swallowed = ZeroDivisionError.new("divided by 0")
    app = lambda do |e|
      e["action_dispatch.exception"] = swallowed
      [500, {}, ["<h1>We're sorry</h1>"]]
    end
    status, = Realuptime::Errors::Rails::RailsMiddleware.new(app).call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/")
    assert_equal 500, status
    assert_equal "ZeroDivisionError", @server.events.fetch(0)["exceptionType"]
  end

  # A stand-in for ActiveJob::Base: records around_perform blocks and runs
  # them around perform, the same shape ActiveJob's callbacks produce.
  class FakeJobBase
    class << self
      # Like ActiveJob's class_attribute callbacks: a subclass sees what its
      # ancestors registered, including blocks registered after it was defined.
      def around
        own = @around ||= []
        superclass.respond_to?(:around) ? superclass.around + own : own
      end

      def around_perform(&block)
        (@around ||= []) << block
      end
    end

    def perform_now
      chain = self.class.around.reverse.inject(-> { perform }) do |inner, wrapper|
        -> { wrapper.call(self, inner) }
      end
      chain.call
    end
  end

  class ChargeJob < FakeJobBase
    def perform
      raise ArgumentError, "card 4242424242424242 declined"
    end
  end

  class QuietJob < FakeJobBase
    def perform
      :done
    end
  end

  def test_active_job_extension_reports_and_reraises
    setup_sdk
    FakeJobBase.include(Realuptime::Errors::Rails::ActiveJobExtension)
    assert_equal :done, QuietJob.new.perform_now
    assert_raises(ArgumentError) { ChargeJob.new.perform_now }
    event = @server.events.fetch(0)
    assert_equal "card [scrubbed] declined", event["message"]
    assert_equal ["active_job", "RailsIntegrationTest::ChargeJob", "ArgumentError"], event["fingerprint"]
    assert_equal({ "framework" => "active_job", "job" => "RailsIntegrationTest::ChargeJob" }, event["tags"])
  end

  def test_options_from_config_and_env
    assert_nil Realuptime::Errors::Rails.options_from({}, {}, "production")
    assert_equal "https://x/ingest/rue_1",
                 Realuptime::Errors::Rails.options_from({}, { "REALUPTIME_ERRORS_DSN" => "https://x/ingest/rue_1" }, "production")[:dsn]
    options = Realuptime::Errors::Rails.options_from(
      { dsn: "https://x/ingest/rue_2", release: "abc", allow_fields: ["user.email"] }, { "REALUPTIME_RELEASE" => "ignored" }, "staging"
    )
    assert_equal({ dsn: "https://x/ingest/rue_2", release: "abc", environment: "staging", allow_fields: ["user.email"],
                   send_device_info: true }, options)
    # The config object can be anything with accessors (ActiveSupport::OrderedOptions answers both).
    config = Struct.new(:dsn, :release, :environment, :allow_fields, :send_device_info).new("https://x/ingest/rue_3", nil, nil, nil, false)
    options = Realuptime::Errors::Rails.options_from(config, {}, "production")
    assert_equal "production", options[:environment]
    assert_equal false, options[:send_device_info]
  end
end
