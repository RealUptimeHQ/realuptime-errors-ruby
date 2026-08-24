# frozen_string_literal: true

require_relative "test_helper"

# Pins the wire contract mirror and the stdlib-only dependency discipline,
# the apps/agent/wire-contract.test.ts convention (as packages/errors-py/
# tests/test_wire_contract.py ports it to Python).
class WireContractTest < Minitest::Test
  include SdkTestSupport

  LIB_DIR = File.expand_path("../lib", __dir__)

  # Everything this SDK is allowed to require: the Ruby standard library it
  # actually uses, its own files, and nothing else, ever.
  ALLOWED_REQUIRES = %w[
    json
    net/http
    uri
    time
    rbconfig
  ].freeze

  def test_stdlib_only
    required = []
    Dir[File.join(LIB_DIR, "**", "*.rb")].sort.each do |file|
      File.read(file).each_line do |line|
        next if line.strip.start_with?("#")

        match = /^\s*require(?:_relative)?\s+["']([^"']+)["']/.match(line)
        required << match[1] if match
      end
    end
    refute_empty required
    foreign = required.reject { |name| name.start_with?("realuptime/") || ALLOWED_REQUIRES.include?(name) }
    assert_equal [], foreign, "the SDK requires something outside the stdlib allow-list"
  end

  def test_gemspec_declares_no_runtime_dependencies
    spec = Gem::Specification.load(File.expand_path("../realuptime-errors.gemspec", __dir__))
    assert_equal [], spec.runtime_dependencies
    assert_equal "MIT", spec.license
    assert_equal Realuptime::Errors::SDK_VERSION, spec.version.to_s
    assert_includes spec.files, "scrub-vectors.json"
  end

  def test_limits_match_the_js_sdk
    assert_equal 50, Realuptime::Errors::MAX_EVENTS_PER_BATCH
    assert_equal 4000, Realuptime::Errors::MAX_MESSAGE_LENGTH
    assert_equal 50, Realuptime::Errors::MAX_FRAMES_PER_EVENT
    assert_equal 512, Realuptime::Errors::MAX_STRING_LENGTH
    assert_equal 200, Realuptime::Errors::BUFFER_MAX
    assert_equal 20, Realuptime::Errors::MAX_BREADCRUMBS_PER_EVENT
    assert_equal 10, Realuptime::Errors::MAX_BREADCRUMB_DATA_ENTRIES
  end

  def test_v2_caps_match_the_js_sdk
    assert_equal 20, Realuptime::Errors::MAX_TAGS_PER_EVENT
    assert_equal 20, Realuptime::Errors::MAX_CONTEXT_ENTRIES
    assert_equal 64, Realuptime::Errors::MAX_CONTEXT_KEY_LENGTH
    assert_equal 20, Realuptime::Errors::MAX_LOCAL_VARS_PER_FRAME
    assert_equal 256, Realuptime::Errors::MAX_LOCAL_VAR_LENGTH
  end

  def test_backoff_and_timeout_match_the_js_sdk
    assert_equal 10.0, Realuptime::Errors::SEND_TIMEOUT_S
    assert_equal 5.0, Realuptime::Errors::BACKOFF_START_S
    assert_equal 300.0, Realuptime::Errors::BACKOFF_MAX_S
  end

  V1_KEYS = %w[
    breadcrumbs breadcrumbsDropped environment exceptionType fingerprint frames message occurredAt release request
  ].freeze

  def test_event_field_names_with_no_state_are_exactly_the_v1_set
    event = Realuptime::Errors.build_event("m", "TypeError", nil)
    assert_equal V1_KEYS, event.keys.sort
  end

  def test_event_field_names_with_v2_scope_are_exactly_the_v2_set
    setup_sdk
    Realuptime::Errors.set_user("id" => "acct_1")
    Realuptime::Errors.set_tag("tenant", "acme")
    Realuptime::Errors.set_context("cart", "1")
    event = Realuptime::Errors.build_event("m", nil, nil)
    assert_equal (V1_KEYS + %w[context tags user]).sort, event.keys.sort
    Realuptime::Errors.close
    setup_sdk(send_device_info: true)
    event = Realuptime::Errors.build_event("m", nil, nil)
    assert_equal (V1_KEYS + %w[device]).sort, event.keys.sort
    assert_equal %w[arch platform runtime runtimeVersion], event["device"].keys.sort
    assert_equal "ruby", event["device"]["runtime"]
  end

  def test_batch_field_names_and_sdk_string
    setup_sdk
    Realuptime::Errors.capture_message("hello")
    batch = @server.batches.fetch(0)
    assert_equal %w[droppedClient events sdk], batch.keys.sort
    assert_equal "realuptime-errors-ruby/#{Realuptime::Errors::SDK_VERSION}", batch["sdk"]
    assert_match(/\Arealuptime-errors-ruby\/\d+\.\d+\.\d+\z/, batch["sdk"])
  end

  def test_frame_field_names
    setup_sdk
    begin
      raise "boom"
    rescue StandardError => e
      Realuptime::Errors.capture_exception(e)
    end
    frame = @server.events.fetch(0)["frames"].fetch(0)
    assert_equal %w[file function inApp line], frame.keys.sort
    assert_kind_of Integer, frame["line"]
    assert_equal true, frame["inApp"]
  end

  # The same frozen v1 golden batch apps/web/app/api/errors/v1/ingest/[key]/
  # route.test.ts ingests: the Ruby SDK's own output for the equivalent
  # capture must carry exactly the same key set and types, so an event this
  # SDK emits is, structurally, the event the server's v1 fixture already
  # proves it accepts.
  V1_GOLDEN_BODY = '{"sdk":"realuptime-errors-js/0.1.0","droppedClient":2,"events":[{"occurredAt":"2026-08-21T09:14:00.000Z",' \
                   '"message":"TypeError: x is undefined","exceptionType":"TypeError","release":"v2.4.1","environment":"production",' \
                   '"frames":[{"file":"src/checkout.ts","function":"processOrder","line":42,"inApp":true}],' \
                   '"request":{"method":"GET","path":"/orders","status":500,"headers":{"x-request-id":"req-42"}},' \
                   '"fingerprint":null,"breadcrumbs":null,"breadcrumbsDropped":0}]}'

  def test_output_matches_the_shared_v1_golden_body_shape
    setup_sdk(release: "v2.4.1", environment: "production")
    begin
      raise TypeError, "x is undefined"
    rescue StandardError => e
      Realuptime::Errors.capture_exception(
        e, request: { "method" => "GET", "path" => "/orders", "status" => 500, "headers" => { "x-request-id" => "req-42" } }
      )
    end
    golden = JSON.parse(V1_GOLDEN_BODY)
    ours = @server.batches.fetch(0)
    assert_equal golden.keys.sort, ours.keys.sort
    golden_event = golden["events"].fetch(0)
    our_event = ours["events"].fetch(0)
    assert_equal golden_event.keys.sort, our_event.keys.sort
    golden_event.each do |key, value|
      next if value.nil?

      assert_equal value.class, our_event[key].class, "type of #{key}"
    end
    assert_equal golden_event["request"], our_event["request"]
    assert_equal golden_event["frames"].fetch(0).keys.sort, our_event["frames"].fetch(0).keys.sort
    assert_equal "TypeError", our_event["exceptionType"]
    assert_equal "x is undefined", our_event["message"]
  end
end
