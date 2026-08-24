# frozen_string_literal: true

require_relative "test_helper"

class TransportTest < Minitest::Test
  include SdkTestSupport

  def capture(n)
    n.times { |i| Realuptime::Errors.capture_message("m#{i}") }
  end

  def test_buffer_is_bounded_and_drops_are_counted_then_reported
    setup_sdk
    @server.fail_with(Errno::ECONNREFUSED)
    capture(1) # first attempt fails -> backoff
    assert_equal 1, @server.calls.length
    capture(250) # buffered while backing off: 251 > 200, 51 evicted
    transport = Realuptime::Errors.transport
    assert_equal 200, transport.buffered_count
    assert_equal 51, transport.dropped_pending
    assert_equal 1, @server.calls.length, "no sends during backoff"

    @server.responses.clear
    @server.respond(200, {})
    @clock.advance(6)
    Realuptime::Errors.flush
    assert_equal 51, @server.batches.fetch(1)["droppedClient"]
    assert_equal 50, @server.batches.fetch(1)["events"].length
    # The same flush drains the rest in 50-event batches; later batches carry 0.
    assert_equal 0, transport.buffered_count
    assert_equal 0, @server.batches.last["droppedClient"]
    assert_equal 5, @server.batches.length # the failed attempt plus 200 events / 50 per batch
  end

  def test_exponential_backoff_with_cap_and_reset_on_success
    setup_sdk
    @server.fail_with(RuntimeError.new("down"))
    capture(1)
    attempts = [@server.calls.length]
    [5, 10, 20, 40, 80, 160, 300, 300].each do |expected_wait|
      @clock.advance(expected_wait - 0.5)
      Realuptime::Errors.flush
      assert_equal attempts.last, @server.calls.length, "must not retry before #{expected_wait}s"
      @clock.advance(0.5)
      Realuptime::Errors.flush
      assert_equal attempts.last + 1, @server.calls.length, "retries at #{expected_wait}s"
      attempts << @server.calls.length
    end
    @server.responses.clear
    @server.respond(200, {})
    @clock.advance(300)
    Realuptime::Errors.flush
    assert_equal 0, Realuptime::Errors.transport.buffered_count
    # Backoff reset: a fresh failure starts again at 5s.
    @server.responses.clear
    @server.fail_with(RuntimeError.new("down"))
    capture(1)
    n = @server.calls.length
    @clock.advance(4.9)
    Realuptime::Errors.flush
    assert_equal n, @server.calls.length
    @clock.advance(0.2)
    Realuptime::Errors.flush
    assert_equal n + 1, @server.calls.length
    assert_equal 1, @logs.count { |l| l.include?("cannot reach") }, "logs once"
  end

  def test_over_quota_429_drops_the_batch_and_pauses_until_reset
    setup_sdk
    @server.respond(429, { "reason" => "over_quota", "resetsAt" => "1970-01-12T14:00:00.000Z" })
    capture(1)
    assert_equal 1, @server.calls.length
    assert_equal 0, Realuptime::Errors.transport.buffered_count, "the refused batch is dropped, not retried"
    capture(1)
    assert_equal 1, @server.calls.length, "paused"
    assert_equal 1, Realuptime::Errors.transport.buffered_count, "buffered until the window resets"
    @clock.now = Time.utc(1970, 1, 12, 14, 0, 1).to_f
    Realuptime::Errors.flush
    assert_equal 2, @server.calls.length
    assert_equal 1, @logs.count { |l| l.include?("quota") }
  end

  def test_over_quota_flag_on_a_2xx_pauses_too
    setup_sdk
    @server.respond(200, { "overQuota" => true, "quota" => { "resetsAt" => "not a date" } })
    capture(1)
    capture(1)
    assert_equal 1, @server.calls.length
    @clock.advance(3601)
    Realuptime::Errors.flush
    assert_equal 2, @server.calls.length
  end

  def test_revoked_key_disables_for_the_process
    setup_sdk
    @server.respond(403, { "reason" => "key_revoked" })
    capture(1)
    capture(5)
    assert_equal 1, @server.calls.length
    assert Realuptime::Errors.transport.disabled?
    assert_equal 0, Realuptime::Errors.transport.buffered_count
    assert_equal 1, @logs.count { |l| l.include?("revoked") }
  end

  def test_malformed_400_drops_the_batch_keeps_the_drop_count_and_continues
    setup_sdk
    @server.fail_with(RuntimeError.new("down")) # 1st call fails, then 400, then 200
    capture(1)
    capture(202) # evicts 3
    @server.responses.clear
    @server.respond(400, { "error" => "bad" }).respond(200, {})
    @clock.advance(6)
    Realuptime::Errors.flush
    # The 400 batch carried droppedClient=3 but was refused; the count was
    # given back and rides the next (accepted) batch.
    assert_equal 3, @server.batches.fetch(1)["droppedClient"]
    assert_equal 3, @server.batches.fetch(2)["droppedClient"]
    assert_equal 0, @server.batches.fetch(3)["droppedClient"]
    assert_equal 0, Realuptime::Errors.transport.buffered_count
    assert_equal 1, @logs.count { |l| l.include?("malformed") }
  end

  def test_other_5xx_backs_off_without_dropping
    setup_sdk
    @server.respond(503, "not json")
    capture(1)
    assert_equal 1, Realuptime::Errors.transport.buffered_count
    @server.responses.clear
    @server.respond(200, {})
    Realuptime::Errors.flush
    assert_equal 1, @server.calls.length, "still backing off"
    @clock.advance(5)
    Realuptime::Errors.flush
    assert_equal 2, @server.calls.length
    assert_equal 0, Realuptime::Errors.transport.buffered_count
  end

  def test_background_thread_delivers_without_a_flush
    setup_sdk(background: true, now: nil)
    delivered = Queue.new
    server = @server
    Realuptime::Errors.close
    Realuptime::Errors.init(dsn: "https://realuptime.test/x", background: true, capture_unhandled: false,
                            send_device_info: false, log: ->(m) { @logs << m },
                            opener: lambda { |url, body|
                              result = server.to_proc.call(url, body)
                              delivered << true
                              result
                            })
    Realuptime::Errors.capture_message("async")
    assert_equal true, delivered.pop # blocks until the worker thread sends (minitest's own timeout guards a hang)
    assert_equal "async", @server.events.fetch(0)["message"]
    deadline = Time.now + 2
    sleep 0.01 while Realuptime::Errors.transport.buffered_count.positive? && Time.now < deadline
    assert_equal 0, Realuptime::Errors.transport.buffered_count
    Realuptime::Errors.close
  end

  def test_opener_returning_non_json_body_is_tolerated
    setup_sdk
    @server.respond(200, "")
    capture(1)
    assert_equal 0, Realuptime::Errors.transport.buffered_count
  end
end
