# frozen_string_literal: true

require_relative "test_helper"

class RackMiddlewareTest < Minitest::Test
  include SdkTestSupport

  def env(overrides = {})
    { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/orders/4242424242424242", "SCRIPT_NAME" => "",
      "HTTP_AUTHORIZATION" => "Bearer secret", "HTTP_COOKIE" => "sid=1" }.merge(overrides)
  end

  def test_reports_an_escaping_exception_with_method_and_path_then_reraises
    setup_sdk
    app = ->(_env) { raise ArgumentError, "boom" }
    middleware = Realuptime::Errors::RackMiddleware.new(app)
    error = assert_raises(ArgumentError) { middleware.call(env) }
    assert_equal "boom", error.message
    event = @server.events.fetch(0)
    # Method + path only; the path went through the scrub; no headers at all.
    assert_equal({ "method" => "POST", "path" => "/orders/[scrubbed]" }, event["request"])
    assert_equal "ArgumentError", event["exceptionType"]
  end

  def test_passes_a_normal_response_through_untouched
    setup_sdk
    app = ->(_env) { [200, { "content-type" => "text/plain" }, ["ok"]] }
    response = Realuptime::Errors::RackMiddleware.new(app).call(env)
    assert_equal [200, { "content-type" => "text/plain" }, ["ok"]], response
    assert_empty @server.calls
  end

  def test_reports_an_exception_a_downstream_framework_swallowed_exactly_once
    setup_sdk
    swallowed = RuntimeError.new("rendered as a 500 page")
    app = lambda do |e|
      e["action_dispatch.exception"] = swallowed
      [500, {}, ["error page"]]
    end
    middleware = Realuptime::Errors::RackMiddleware.new(app)
    middleware.call(env)
    # A second pass with the SAME exception object (a re-raise further up the
    # stack, say) is not double-counted.
    assert_raises(RuntimeError) { Realuptime::Errors::RackMiddleware.new(->(_e) { raise swallowed }).call(env) }
    assert_equal 1, @server.events.length
  end

  def test_mount_prefix_is_part_of_the_path
    setup_sdk
    app = ->(_env) { raise "x" }
    assert_raises(RuntimeError) do
      Realuptime::Errors::RackMiddleware.new(app).call(env("SCRIPT_NAME" => "/api", "PATH_INFO" => "/health"))
    end
    assert_equal "/api/health", @server.events.fetch(0)["request"]["path"]
  end

  def test_never_breaks_the_app_when_the_sdk_is_not_initialized
    Realuptime::Errors.close
    app = ->(_env) { raise "x" }
    assert_raises(RuntimeError) { Realuptime::Errors::RackMiddleware.new(app).call(env) }
  end
end
