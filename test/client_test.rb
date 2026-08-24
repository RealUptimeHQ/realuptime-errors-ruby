# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  include SdkTestSupport

  def test_init_without_dsn_logs_once_and_stays_inert
    logs = []
    Realuptime::Errors.init(dsn: nil, log: ->(m) { logs << m })
    refute Realuptime::Errors.initialized?
    assert_equal 1, logs.length
    assert_match(/without a dsn/, logs.first)
    Realuptime::Errors.capture_message("ignored")
  end

  def test_capture_exception_builds_frames_and_scrubs_the_message
    setup_sdk(release: "v1.2.3", environment: "test")
    begin
      raise ArgumentError, "token sk_live_abcdefgh12345678 rejected"
    rescue StandardError => e
      Realuptime::Errors.capture_exception(e)
    end
    event = @server.events.fetch(0)
    assert_equal "token [scrubbed] rejected", event["message"]
    assert_equal "ArgumentError", event["exceptionType"]
    assert_equal "v1.2.3", event["release"]
    assert_equal "test", event["environment"]
    assert_equal __FILE__, event["frames"].fetch(0)["file"]
    assert_equal "2026-08-21T00:00:00.000Z".length, event["occurredAt"].length
    assert_equal "1970-01-12T13:46:40.000Z", event["occurredAt"]
  end

  def test_exception_with_empty_message_uses_the_class_name
    setup_sdk
    begin
      raise RuntimeError
    rescue StandardError => e
      Realuptime::Errors.capture_exception(e)
    end
    assert_equal "RuntimeError", @server.events.fetch(0)["message"]
  end

  def test_capture_exception_accepts_a_non_exception_value
    setup_sdk
    Realuptime::Errors.capture_exception("a plain string")
    event = @server.events.fetch(0)
    assert_equal "a plain string", event["message"]
    assert_nil event["exceptionType"]
    assert_nil event["frames"]
  end

  def test_capture_message_and_per_capture_overrides
    setup_sdk
    Realuptime::Errors.capture_message("hello", release: "r2", environment: "staging", fingerprint: %w[a b],
                                                request: { method: "GET", path: "/x" })
    event = @server.events.fetch(0)
    assert_equal "hello", event["message"]
    assert_equal "r2", event["release"]
    assert_equal "staging", event["environment"]
    assert_equal %w[a b], event["fingerprint"]
    assert_equal({ "method" => "GET", "path" => "/x" }, event["request"])
  end

  def test_removed_headers_and_allow_fields
    setup_sdk(allow_fields: ["x-request-id"])
    Realuptime::Errors.capture_message("m", request: { "method" => "GET", "path" => "/",
                                                       "headers" => { "Authorization" => "Bearer abc", "x-request-id" => "r1" } })
    headers = @server.events.fetch(0)["request"]["headers"]
    assert_equal "[scrubbed]", headers["Authorization"]
    assert_equal "r1", headers["x-request-id"]
  end

  def test_breadcrumbs_are_bounded_and_evictions_are_counted
    setup_sdk
    25.times { |i| Realuptime::Errors.add_breadcrumb("crumb #{i}", category: "test", data: { "k" => "v#{i}" }) }
    Realuptime::Errors.capture_message("m")
    event = @server.events.fetch(0)
    assert_equal 20, event["breadcrumbs"].length
    assert_equal "crumb 24", event["breadcrumbs"].last["message"]
    assert_equal 5, event["breadcrumbsDropped"]
    assert_equal %w[category data message timestamp], event["breadcrumbs"].first.keys.sort
  end

  def test_breadcrumb_values_are_scrubbed
    setup_sdk
    Realuptime::Errors.add_breadcrumb("paid with 4242424242424242", data: { "card" => "4111 1111 1111 1111", "n" => 1 })
    Realuptime::Errors.capture_message("m")
    crumb = @server.events.fetch(0)["breadcrumbs"].fetch(0)
    assert_equal "paid with [scrubbed]", crumb["message"]
    assert_equal({ "card" => "[scrubbed]" }, crumb["data"])
  end

  def test_sticky_user_is_scrubbed_by_default_and_opt_in_is_per_field
    setup_sdk
    Realuptime::Errors.set_user(id: "acct_1", email: "alice@example.com", username: "alice", address: "secret")
    Realuptime::Errors.capture_message("m")
    assert_equal({ "id" => "acct_1", "email" => "[scrubbed]", "username" => "[scrubbed]" }, @server.events.fetch(0)["user"])

    Realuptime::Errors.close
    setup_sdk(allow_fields: ["user.email"])
    Realuptime::Errors.set_user("id" => "acct_1", "email" => "alice@example.com", "username" => "alice")
    Realuptime::Errors.capture_message("m")
    assert_equal({ "id" => "acct_1", "email" => "alice@example.com", "username" => "[scrubbed]" },
                 @server.events.fetch(0)["user"])
  end

  def test_set_user_nil_clears_and_per_capture_user_merges_over_scope
    setup_sdk
    Realuptime::Errors.set_user("id" => "acct_1")
    Realuptime::Errors.capture_message("m", user: { "id" => "acct_2" })
    assert_equal "acct_2", @server.events.fetch(0)["user"]["id"]
    Realuptime::Errors.set_user(nil)
    Realuptime::Errors.capture_message("m")
    refute @server.events.fetch(1).key?("user")
  end

  def test_tags_and_context_are_sticky_bounded_and_scrubbed
    setup_sdk
    Realuptime::Errors.set_tag("tenant", "acme")
    Realuptime::Errors.set_tags("region" => "eu", "secret" => "sk_live_abcdefgh12345678")
    Realuptime::Errors.set_context("cart", "49.99")
    Realuptime::Errors.set_context("a" => "1", "b" => "2")
    25.times { |i| Realuptime::Errors.set_tag("extra#{i}", "x") }
    Realuptime::Errors.capture_message("m", tags: { "per" => "capture" }, context: { "c" => "3" })
    event = @server.events.fetch(0)
    assert_equal "acme", event["tags"]["tenant"]
    assert_equal "[scrubbed]", event["tags"]["secret"]
    assert_equal "capture", event["tags"]["per"]
    assert_operator event["tags"].length, :<=, 21 # 20 sticky + per-capture merge
    assert_equal({ "cart" => "49.99", "a" => "1", "b" => "2", "c" => "3" }, event["context"])

    Realuptime::Errors.set_tag("tenant", nil)
    Realuptime::Errors.set_context(nil)
    Realuptime::Errors.capture_message("m")
    refute @server.events.fetch(1)["tags"].key?("tenant")
    refute @server.events.fetch(1).key?("context")
  end

  def test_v1_payload_stays_byte_identical_when_no_v2_api_is_used
    setup_sdk
    Realuptime::Errors.capture_message("m")
    event = @server.events.fetch(0)
    %w[user tags context device].each { |key| refute event.key?(key), "#{key} must be absent" }
  end

  def test_message_and_string_caps
    setup_sdk
    # Spaced words: a 5000-character run of one letter is token-shaped and
    # would (correctly) be scrubbed, which is not what this test measures.
    Realuptime::Errors.capture_message("word " * 1000, tags: { "k" => "yo " * 200 })
    event = @server.events.fetch(0)
    assert_equal 4000, event["message"].length
    assert_equal 512, event["tags"]["k"].length
  end

  def test_public_api_never_raises
    setup_sdk
    assert_nil Realuptime::Errors.capture_exception(Object.new)
    assert_nil Realuptime::Errors.add_breadcrumb(nil)
    assert_nil Realuptime::Errors.set_user(42)
    assert_nil Realuptime::Errors.set_tag(nil, nil)
    assert_nil Realuptime::Errors.set_context(42, 42)
    assert_nil Realuptime::Errors.flush
    Realuptime::Errors.close
    # After close every call is a no-op, not a NoMethodError.
    assert_nil Realuptime::Errors.capture_message("m")
    assert_nil Realuptime::Errors.flush
  end

  def test_in_app_detection
    assert Realuptime::Errors.in_app?("/srv/app/app/models/user.rb")
    refute Realuptime::Errors.in_app?("/usr/local/bundle/gems/rack-3.0/lib/rack.rb")
    refute Realuptime::Errors.in_app?("<internal:kernel>")
    refute Realuptime::Errors.in_app?(File.join(RbConfig::CONFIG["rubylibdir"], "net/http.rb"))
  end

  def test_frames_are_capped
    setup_sdk
    deep = lambda do |n|
      n.zero? ? raise("deep") : deep.call(n - 1)
    end
    begin
      deep.call(120)
    rescue StandardError => e
      Realuptime::Errors.capture_exception(e)
    end
    assert_equal 50, @server.events.fetch(0)["frames"].length
  end
end
