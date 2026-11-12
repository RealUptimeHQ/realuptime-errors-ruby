# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "time"

module Realuptime
  module Errors
    # Batched, buffered, backed-off delivery. Mirrors errors-js/
    # client.ts and the Python SDK's _Transport: over_quota pauses until the
    # reset instant, key_revoked disables for the process lifetime,
    # transient failures back off exponentially (5s doubling to 300s), and
    # client-side drops ride the next successful batch as droppedClient so
    # they reach the product's visible drop counters. Nothing here ever
    # raises out to the host app.
    #
    # Delivery runs on ONE background thread per process, woken by enqueue
    # and by the backoff timer. Forking servers (Puma clustered, Unicorn,
    # Sidekiq under a preforking supervisor) are handled by re-spawning the
    # worker when the pid changes: a thread does not survive fork, and a
    # buffer that was filling in the parent must keep flushing in the child.
    # `flush` is synchronous and is what at_exit, tests and job-finished
    # hooks call.
    class Transport
      attr_reader :endpoint

      def initialize(endpoint, opener: nil, now: nil, log: nil, background: true)
        @endpoint = endpoint
        @opener = opener || method(:http_post)
        @now = now || -> { Time.now.to_f }
        @log_fn = log || ->(message) { warn(message) }
        @background = background
        @lock = Mutex.new
        @wake = ConditionVariable.new
        @events = []
        @dropped_since_report = 0
        @backoff_s = 0.0
        @next_attempt_at = 0.0
        @paused_until = 0.0
        @disabled = false
        @logged_kinds = {}
        @worker = nil
        @worker_pid = nil
        @closing = false
      end

      # Test and diagnostics seams.
      def buffered_count
        @lock.synchronize { @events.length }
      end

      def dropped_pending
        @lock.synchronize { @dropped_since_report }
      end

      def disabled?
        @lock.synchronize { @disabled }
      end

      def enqueue(event)
        @lock.synchronize do
          return if @disabled

          if @events.length >= BUFFER_MAX
            @events.shift
            @dropped_since_report += 1
          end
          @events << event
        end
        if @background
          ensure_worker
          @lock.synchronize { @wake.signal }
        else
          flush
        end
      end

      # Sends what is due, synchronously on the calling thread. Never raises.
      def flush
        deliver
      rescue StandardError => e
        log_once("internal", "delivery failed internally: #{e.class}: #{e.message}")
      end

      # Stops the worker thread (test seam / at_exit).
      def close
        @lock.synchronize do
          @closing = true
          @wake.broadcast
        end
        worker = @worker
        worker&.join(1) if worker && worker != Thread.current
        @worker = nil
      end

      private

      def http_post(url, body)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = SEND_TIMEOUT_S
        http.read_timeout = SEND_TIMEOUT_S
        req = Net::HTTP::Post.new(uri.request_uri, "content-type" => "application/json")
        req.body = body
        res = http.request(req)
        [res.code.to_i, res.body]
      end

      def ensure_worker
        pid = Process.pid
        @lock.synchronize do
          return if @worker&.alive? && @worker_pid == pid

          @worker_pid = pid
          @closing = false
          @worker = Thread.new { worker_loop }
          @worker.name = "realuptime-errors" if @worker.respond_to?(:name=)
        end
      end

      def worker_loop
        loop do
          wait_s = nil
          @lock.synchronize do
            return if @closing

            if @events.empty?
              @wake.wait(@lock)
            else
              now = @now.call
              due = [@next_attempt_at, @paused_until].max
              wait_s = due - now if due > now
              @wake.wait(@lock, wait_s) if wait_s
            end
          end
          flush
        end
      rescue StandardError
        nil
      end

      def log_once(kind, message)
        return if @logged_kinds[kind]

        @logged_kinds[kind] = true
        begin
          @log_fn.call("[realuptime-errors] #{message}")
        rescue StandardError
          nil
        end
      end

      def deliver
        loop do
          events = nil
          dropped_client = 0
          @lock.synchronize do
            now = @now.call
            return if @disabled || @events.empty? || now < @next_attempt_at || now < @paused_until

            events = @events[0, MAX_EVENTS_PER_BATCH]
            dropped_client = @dropped_since_report
            @dropped_since_report = 0
          end
          batch = { "sdk" => "#{SDK_NAME}/#{SDK_VERSION}", "droppedClient" => dropped_client, "events" => events }
          begin
            status, raw = @opener.call(@endpoint, JSON.generate(batch))
          rescue StandardError
            @lock.synchronize { @dropped_since_report += dropped_client }
            back_off("network", "cannot reach the ingest endpoint; buffering and retrying")
            return
          end
          body = begin
            raw && !raw.empty? ? JSON.parse(raw) : {}
          rescue StandardError
            {}
          end
          body = {} unless body.is_a?(Hash)

          if status >= 200 && status < 300
            @lock.synchronize do
              @events.shift(events.length)
              @backoff_s = 0.0
              @next_attempt_at = 0.0
            end
            if body["overQuota"]
              pause_until((body["quota"] || {})["resetsAt"])
              log_once("over-quota", OVER_QUOTA_MESSAGE)
              return
            end
            next
          end

          reason = body["reason"]
          if status == 403 && reason == "key_revoked"
            @lock.synchronize do
              @disabled = true
              @events.clear
            end
            log_once(
              "revoked",
              "this project's ingest key was revoked; error reporting is disabled for this process. " \
              "Rotate the key in realuptime Errors settings and redeploy with the new DSN."
            )
            return
          end
          if status == 429 && reason == "over_quota"
            @lock.synchronize { @events.shift(events.length) }
            pause_until(body["resetsAt"])
            log_once("over-quota", OVER_QUOTA_MESSAGE)
            return
          end
          if status == 400
            @lock.synchronize do
              @events.shift(events.length)
              @dropped_since_report += dropped_client
            end
            log_once(
              "malformed",
              "the server refused a batch as malformed: #{body["error"] || "no detail"}. This is an SDK bug worth reporting."
            )
            next
          end

          @lock.synchronize { @dropped_since_report += dropped_client }
          back_off("transient", "ingest endpoint answered #{status}; buffering and retrying")
          return
        end
      end

      OVER_QUOTA_MESSAGE = "monthly event quota reached; pausing until the window resets. " \
                           "Dropped events are counted and shown on your realuptime Errors dashboard."

      def pause_until(resets_at)
        parsed = nil
        if resets_at.is_a?(String)
          begin
            parsed = Time.iso8601(resets_at).to_f
          rescue StandardError
            parsed = nil
          end
        end
        @lock.synchronize { @paused_until = parsed || (@now.call + 3600.0) }
      end

      def back_off(kind, message)
        @lock.synchronize do
          @backoff_s = @backoff_s <= 0 ? BACKOFF_START_S : [@backoff_s * 2, BACKOFF_MAX_S].min
          @next_attempt_at = @now.call + @backoff_s
        end
        log_once(kind, "#{message} (backing off).")
      end
    end
  end
end
