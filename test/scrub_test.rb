# frozen_string_literal: true

require_relative "test_helper"

# Drives the SHARED scrub vectors through the Ruby SDK. The vectors file is
# the single source of truth for scrub semantics across the JS SDK, the
# Python SDK, this SDK and the server's second net; this suite must never
# grow expectations of its own. The copy it reads is the one vendored into
# the gem (scrub-vectors.json at the gem root); vendored_vectors_test.rb
# asserts that copy is byte-identical to errors-js/scrub-vectors.json.
class ScrubVectorsTest < Minitest::Test
  VECTORS_PATH = File.expand_path("../scrub-vectors.json", __dir__)

  BASE = {
    "occurredAt" => "2026-08-21T00:00:00.000Z",
    "message" => "",
    "exceptionType" => nil,
    "release" => nil,
    "environment" => nil,
    "frames" => nil,
    "request" => nil,
    "fingerprint" => nil,
    "breadcrumbs" => nil,
    "breadcrumbsDropped" => 0
  }.freeze

  def vectors
    JSON.parse(File.read(VECTORS_PATH))["vectors"]
  end

  def test_has_enough_vectors_to_mean_something
    assert_operator vectors.length, :>=, 15
  end

  def test_all_vectors
    vectors.each do |vector|
      event = BASE.merge(vector["event"])
      expected = BASE.merge(vector["expected"])
      output = Realuptime::Errors::Scrub.scrub_event(event, vector["allowFields"])
      assert_equal expected, output, "vector: #{vector["name"]}"
    end
  end

  def test_never_mutates_the_input
    event = BASE.merge(
      "message" => "sk_live_abcdefgh12345678",
      "request" => { "method" => "GET", "path" => "/x", "status" => 500, "headers" => { "cookie" => "sid=1" } }
    )
    snapshot = JSON.parse(JSON.generate(event))
    Realuptime::Errors::Scrub.scrub_event(event)
    assert_equal snapshot, event
  end

  def test_scrub_string_is_exposed_for_direct_use
    assert_equal "card [scrubbed] ok", Realuptime::Errors::Scrub.scrub_string("card 4242424242424242 ok")
  end
end

# Error messages often carry user input, and this runs in the customer's own
# process: a pattern that backtracks on it stalls their app.
class ScrubLinearTimeTest < Minitest::Test
  def test_hostile_scheme_and_colon_run_is_fast
    hostile = ("a." * 300) + "://" + (":" * 2000)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Realuptime::Errors::Scrub.scrub_string(hostile)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.25
  end
end
