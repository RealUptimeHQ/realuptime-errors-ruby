# frozen_string_literal: true

require_relative "test_helper"

# The gem vendors scrub-vectors.json so it can test itself standalone (the
# public mirror has no sibling errors-js package). That copy must be the
# SAME bytes as the canonical file, or "parity" would be parity with a
# stale snapshot. Inside the monorepo this test compares the two; in the
# published mirror the canonical path does not exist and the test skips,
# saying so.
class VendoredVectorsTest < Minitest::Test
  VENDORED = File.expand_path("../scrub-vectors.json", __dir__)
  CANONICAL = File.expand_path("../../errors-js/scrub-vectors.json", __dir__)

  def test_vendored_copy_is_byte_identical_to_the_canonical_vectors
    skip "canonical errors-js/scrub-vectors.json not present (standalone gem checkout)" unless File.exist?(CANONICAL)

    vendored = File.binread(VENDORED)
    canonical = File.binread(CANONICAL)
    assert_equal canonical.bytesize, vendored.bytesize, "scrub-vectors.json size differs; re-copy from errors-js"
    assert vendored == canonical, "errors-ruby/scrub-vectors.json differs from errors-js/scrub-vectors.json; " \
                                  "run: cp errors-js/scrub-vectors.json errors-ruby/scrub-vectors.json"
  end

  def test_vendored_copy_is_the_v2_vector_set
    data = JSON.parse(File.read(VENDORED))
    assert_equal 2, data["version"]
    assert(data["vectors"].any? { |v| v["name"].start_with?("v2 ") })
  end
end
