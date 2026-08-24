# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "json"
require "realuptime/errors"

# Shared seams for the suite: a fake clock, a recording opener, and a
# capturing logger, so no test touches the network or sleeps.
module SdkTestSupport
  class FakeClock
    attr_accessor :now

    def initialize(start = 1_000_000.0)
      @now = start
    end

    def call
      @now
    end

    def advance(seconds)
      @now += seconds
    end
  end

  class FakeServer
    attr_reader :calls, :responses

    def initialize
      @calls = []
      @responses = []
    end

    # Queue a response; the last one repeats once the queue is exhausted.
    def respond(status, body = {})
      @responses << [status, body.is_a?(String) ? body : JSON.generate(body)]
      self
    end

    def fail_with(error)
      @responses << error
      self
    end

    def to_proc
      server = self
      lambda do |url, body|
        server.calls << [url, JSON.parse(body)]
        response = server.responses.length > 1 ? server.responses.shift : server.responses.first
        response ||= [200, "{}"]
        raise response if response.is_a?(Exception) || response.is_a?(Class)

        response
      end
    end

    def batches
      @calls.map { |(_, batch)| batch }
    end

    def events
      batches.flat_map { |batch| batch["events"] }
    end
  end

  def setup_sdk(**options)
    @clock = FakeClock.new
    @server = FakeServer.new
    @logs = []
    Realuptime::Errors.close
    Realuptime::Errors.init(
      **{
        dsn: "https://realuptime.test/api/errors/v1/ingest/rue_test",
        background: false,
        capture_unhandled: false,
        send_device_info: false,
        opener: @server.to_proc,
        now: @clock,
        log: ->(message) { @logs << message }
      }.merge(options)
    )
  end

  def teardown
    Realuptime::Errors.close
    super
  end
end
