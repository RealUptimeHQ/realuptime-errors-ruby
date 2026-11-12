# frozen_string_literal: true

# realuptime-errors: zero-dependency Ruby error tracking SDK for RealUptime
# Errors (the internal-docs repo's errors-plan.md, Linear REA-255).
#
# One wire contract with the JS and Python SDKs (errors-js/types.ts);
# the shared scrub vectors (scrub-vectors.json, vendored into this gem and
# asserted byte-identical to errors-js/scrub-vectors.json) pin all
# three SDKs and the server's second net to identical scrubbing. Ruby
# standard library only (json, net/http, uri, time, rbconfig): this code
# runs inside customer processes and its dependency graph must be
# auditable at a glance, enforced by test/wire_contract_test.rb.
#
# Contract with the host app, non-negotiable: THIS SDK NEVER RAISES out of
# a public method. A broken SDK logs once and goes quiet; an error tracker
# that crashes the app it watches is worse than none.
#
# Usage:
#
#   require "realuptime/errors"
#   Realuptime::Errors.init(dsn: "https://ingest.realuptime.io/api/errors/v1/ingest/rue_...",
#                           release: "v2.4.1", environment: "production")
#   ...
#   Realuptime::Errors.capture_exception(error)
#
# Rack:    use Realuptime::Errors::RackMiddleware
# Rails:   require "realuptime/errors/rails"   (Railtie installs everything)
# Sidekiq: require "realuptime/errors/sidekiq"; Realuptime::Errors::Sidekiq.install

require "rbconfig"
require "realuptime/errors/version"
require "realuptime/errors/scrub"

module Realuptime
  module Errors
    # Mirrored from errors-js/types.ts and pinned by
    # test/wire_contract_test.rb.
    MAX_EVENTS_PER_BATCH = 50
    MAX_MESSAGE_LENGTH = 4000
    MAX_FRAMES_PER_EVENT = 50
    MAX_STRING_LENGTH = 512
    MAX_BREADCRUMBS_PER_EVENT = 20
    MAX_BREADCRUMB_DATA_ENTRIES = 10
    BUFFER_MAX = 200

    # v2 caps (REA-182), mirrored from errors-js/types.ts.
    MAX_TAGS_PER_EVENT = 20
    MAX_CONTEXT_ENTRIES = 20
    MAX_CONTEXT_KEY_LENGTH = 64
    MAX_LOCAL_VARS_PER_FRAME = 20
    MAX_LOCAL_VAR_LENGTH = 256

    SEND_TIMEOUT_S = 10.0
    BACKOFF_START_S = 5.0
    BACKOFF_MAX_S = 300.0

    SCRUBBED = Scrub::SCRUBBED

    USER_KEYS = %w[id email username].freeze

    # Everything init() keeps. Breadcrumbs and the v2 sticky scope are
    # bounded at WRITE time so a long-lived process cannot grow them without
    # limit; the eviction count rides every event as breadcrumbsDropped.
    class State
      attr_reader :dsn, :release, :environment, :allow_fields, :transport, :device, :lock
      attr_accessor :breadcrumbs, :breadcrumbs_evicted, :user, :tags, :context

      def initialize(dsn:, release:, environment:, allow_fields:, transport:, device:)
        @dsn = dsn
        @release = release
        @environment = environment
        @allow_fields = allow_fields
        @transport = transport
        @device = device
        @lock = Mutex.new
        @breadcrumbs = []
        @breadcrumbs_evicted = 0
        @user = nil
        @tags = {}
        @context = {}
      end
    end

    @state = nil
    @at_exit_installed = false

    class << self
      # Initializes the SDK. Safe to call twice (last call wins); a missing
      # DSN logs once and stays inert. Never raises.
      #
      #   dsn                 the project's ingest URL (required)
      #   release             e.g. a git SHA or version tag
      #   environment         e.g. "production"
      #   allow_fields        per-field opt-back-in: lowercased header names
      #                       ("x-request-id") and the dotted identity names
      #                       "user.email" / "user.username". Never a global
      #                       switch.
      #   capture_unhandled   installs an at_exit hook that reports the
      #                       exception a process is dying from (default on)
      #   send_device_info    runtime/platform facts about THIS process,
      #                       never hostname or IP (default on)
      #   background          deliver on a background thread (default on);
      #                       false delivers inline on every capture
      #
      # Keyword seams opener:/now:/log: exist for tests.
      def init(dsn: nil, release: nil, environment: nil, allow_fields: nil, capture_unhandled: true,
               send_device_info: true, background: true, opener: nil, now: nil, log: nil)
        unless dsn.is_a?(String) && !dsn.empty?
          safe_log(log, "[realuptime-errors] init called without a dsn; error reporting is disabled.")
          return nil
        end
        transport = Transport.new(dsn, opener: opener, now: now, log: log, background: background)
        @state = State.new(
          dsn: dsn,
          release: release,
          environment: environment,
          allow_fields: Array(allow_fields).map(&:to_s),
          transport: transport,
          device: send_device_info ? detect_device : nil
        )
        install_at_exit if capture_unhandled
        nil
      rescue StandardError => e
        safe_log(log, "[realuptime-errors] init failed: #{e.class}: #{e.message}")
        nil
      end

      def initialized?
        !@state.nil?
      end

      # Reports an exception. Never raises. user/tags/context are per-capture
      # overrides merged OVER the sticky scope set by set_user/set_tag/
      # set_context.
      def capture_exception(exc, request: nil, fingerprint: nil, release: nil, environment: nil,
                            user: nil, tags: nil, context: nil)
        state = @state
        return nil if state.nil?

        event = if exc.is_a?(Exception)
                  message = exc.message.to_s
                  message = exc.class.name.to_s if message.empty?
                  build_event(message, exc.class.name.to_s, frames_from_exception(exc),
                              request: request, fingerprint: fingerprint, release: release,
                              environment: environment, user: user, tags: tags, context: context)
                else
                  build_event(exc.to_s, nil, nil, request: request, fingerprint: fingerprint,
                                                  release: release, environment: environment,
                                                  user: user, tags: tags, context: context)
                end
        state.transport.enqueue(Scrub.scrub_event(event, state.allow_fields))
        nil
      rescue StandardError => e
        safe_log(nil, "[realuptime-errors] capture_exception failed: #{e.class}: #{e.message}")
        nil
      end

      # Reports a plain message. Never raises.
      def capture_message(message, request: nil, fingerprint: nil, release: nil, environment: nil,
                          user: nil, tags: nil, context: nil)
        state = @state
        return nil if state.nil?

        event = build_event(message.to_s, nil, nil, request: request, fingerprint: fingerprint,
                                                    release: release, environment: environment,
                                                    user: user, tags: tags, context: context)
        state.transport.enqueue(Scrub.scrub_event(event, state.allow_fields))
        nil
      rescue StandardError
        nil
      end

      # Records one breadcrumb onto the bounded trail. Rides the NEXT captured
      # event, newest last, at most MAX_BREADCRUMBS_PER_EVENT; older entries
      # are evicted and the eviction count rides as breadcrumbsDropped.
      def add_breadcrumb(message, category: nil, data: nil)
        state = @state
        return nil if state.nil? || !message.is_a?(String)

        crumb_data = nil
        if data.is_a?(Hash)
          crumb_data = {}
          data.first(MAX_BREADCRUMB_DATA_ENTRIES).each do |name, value|
            crumb_data[clip(name.to_s, MAX_STRING_LENGTH)] = clip(value, MAX_STRING_LENGTH) if value.is_a?(String)
          end
        end
        crumb = {
          "timestamp" => iso_time(now_f),
          "category" => category.is_a?(String) ? clip(category, 100) : nil,
          "message" => clip(message, MAX_STRING_LENGTH),
          "data" => crumb_data
        }
        state.lock.synchronize do
          state.breadcrumbs << crumb
          if state.breadcrumbs.length > MAX_BREADCRUMBS_PER_EVENT
            state.breadcrumbs.shift
            state.breadcrumbs_evicted += 1
          end
        end
        nil
      rescue StandardError
        nil
      end

      # Sticky identity applied to every subsequent event; nil clears it.
      # Only id / email / username are carried. email and username are
      # "[scrubbed]" before serialization unless the matching allow_fields
      # entry is set. Never raises.
      def set_user(user)
        state = @state
        return nil if state.nil?

        next_user = nil
        if user.is_a?(Hash)
          next_user = {}
          USER_KEYS.each do |key|
            value = user[key] || user[key.to_sym]
            next_user[key] = clip(value, MAX_STRING_LENGTH) if value.is_a?(String)
          end
          next_user = nil if next_user.empty?
        end
        state.lock.synchronize { state.user = next_user }
        nil
      rescue StandardError
        nil
      end

      # One sticky tag; nil removes it. Tags past MAX_TAGS_PER_EVENT are
      # ignored rather than evicting an existing one. Never raises.
      def set_tag(key, value)
        state = @state
        return nil if state.nil?

        key = key.to_s
        return nil if key.empty?

        name = clip(key, MAX_CONTEXT_KEY_LENGTH)
        state.lock.synchronize do
          if value.nil?
            state.tags.delete(name)
          elsif value.is_a?(String)
            unless !state.tags.key?(name) && state.tags.length >= MAX_TAGS_PER_EVENT
              state.tags[name] = clip(value, MAX_STRING_LENGTH)
            end
          end
        end
        nil
      rescue StandardError
        nil
      end

      def set_tags(tags)
        return nil unless tags.is_a?(Hash)

        tags.each { |name, value| set_tag(name, value) }
        nil
      rescue StandardError
        nil
      end

      # One sticky custom-context entry, or a whole Hash merged in.
      # set_context(nil) clears everything. Never raises.
      def set_context(key, value = nil)
        state = @state
        return nil if state.nil?

        if key.nil?
          state.lock.synchronize { state.context = {} }
          return nil
        end
        if key.is_a?(Hash)
          key.each { |name, entry| set_context(name, entry) }
          return nil
        end
        key = key.to_s
        return nil if key.empty?

        name = clip(key, MAX_CONTEXT_KEY_LENGTH)
        state.lock.synchronize do
          if value.nil?
            state.context.delete(name)
          elsif value.is_a?(String)
            unless !state.context.key?(name) && state.context.length >= MAX_CONTEXT_ENTRIES
              state.context[name] = clip(value, MAX_STRING_LENGTH)
            end
          end
        end
        nil
      rescue StandardError
        nil
      end

      # Delivers anything buffered, synchronously. Never raises.
      def flush
        @state&.transport&.flush
        nil
      rescue StandardError
        nil
      end

      # Test seam: drops state and stops the delivery thread.
      def close
        state = @state
        @state = nil
        state&.transport&.close
        nil
      rescue StandardError
        nil
      end

      # Exposed for tests and adapters.
      def transport
        @state&.transport
      end

      # Builds one wire event (string-keyed Hash). v2 fields are emitted only
      # when NON-EMPTY, so an integration that never touches the v2 API keeps
      # producing byte-identical v1 payloads.
      def build_event(message, exception_type, frames, request: nil, fingerprint: nil, release: nil,
                      environment: nil, user: nil, tags: nil, context: nil)
        state = @state
        breadcrumbs = nil
        breadcrumbs_dropped = 0
        scope_user = nil
        scope_tags = {}
        scope_context = {}
        device = nil
        if state
          state.lock.synchronize do
            breadcrumbs = state.breadcrumbs.dup unless state.breadcrumbs.empty?
            breadcrumbs_dropped = state.breadcrumbs_evicted
            scope_user = state.user.dup if state.user
            scope_tags = state.tags.dup
            scope_context = state.context.dup
            device = state.device.dup if state.device
          end
        end
        event = {
          "occurredAt" => iso_time(now_f),
          "message" => clip(message.to_s, MAX_MESSAGE_LENGTH),
          "exceptionType" => exception_type ? clip(exception_type, MAX_STRING_LENGTH) : nil,
          "release" => release || state&.release,
          "environment" => environment || state&.environment,
          "frames" => frames,
          "request" => normalize_request(request),
          "fingerprint" => fingerprint,
          "breadcrumbs" => breadcrumbs,
          "breadcrumbsDropped" => breadcrumbs_dropped
        }
        merged_user = scope_user
        if user.is_a?(Hash)
          merged_user = (scope_user || {}).dup
          USER_KEYS.each do |key|
            value = user[key] || user[key.to_sym]
            merged_user[key] = clip(value, MAX_STRING_LENGTH) if value.is_a?(String)
          end
        end
        event["user"] = merged_user if merged_user && !merged_user.empty?
        merged_tags = scope_tags.merge(bounded_map(tags, MAX_TAGS_PER_EVENT))
        event["tags"] = merged_tags unless merged_tags.empty?
        merged_context = scope_context.merge(bounded_map(context, MAX_CONTEXT_ENTRIES))
        event["context"] = merged_context unless merged_context.empty?
        event["device"] = device if device
        event
      end

      # Wire frames from a Ruby exception, innermost first (Ruby's own
      # backtrace order), capped at MAX_FRAMES_PER_EVENT. inApp is a
      # best-effort guess: not under a gems directory, not the Ruby stdlib,
      # not an <internal:...> frame.
      def frames_from_exception(exc)
        locations = exc.backtrace_locations
        frames = if locations
                   locations.first(MAX_FRAMES_PER_EVENT).map do |loc|
                     path = loc.absolute_path || loc.path || ""
                     {
                       "file" => clip(path, MAX_STRING_LENGTH),
                       "function" => loc.label ? clip(loc.label, MAX_STRING_LENGTH) : nil,
                       "line" => loc.lineno,
                       "inApp" => in_app?(path)
                     }
                   end
                 else
                   (exc.backtrace || []).first(MAX_FRAMES_PER_EVENT).map { |line| parse_backtrace_line(line) }
                 end
        frames.empty? ? nil : frames
      rescue StandardError
        nil
      end

      def in_app?(path)
        return false if path.empty? || path.start_with?("<internal:")
        return false if path.include?("/gems/") || path.include?("/bundler/gems/")

        rubylib = RbConfig::CONFIG["rubylibdir"]
        return false if rubylib && !rubylib.empty? && path.start_with?(rubylib)

        true
      end

      private

      def parse_backtrace_line(line)
        match = /\A(.*?):(\d+)(?::in [`'](.*)')?\z/.match(line.to_s)
        if match
          { "file" => clip(match[1], MAX_STRING_LENGTH), "function" => match[3] ? clip(match[3], MAX_STRING_LENGTH) : nil,
            "line" => match[2].to_i, "inApp" => in_app?(match[1]) }
        else
          { "file" => clip(line.to_s, MAX_STRING_LENGTH), "function" => nil, "line" => nil, "inApp" => false }
        end
      end

      # v2: the runtime facts, read out of this process. Never the hostname,
      # the local IP or a container id.
      def detect_device
        device = {
          "runtime" => "ruby",
          "runtimeVersion" => RUBY_VERSION.to_s,
          "platform" => clip(RbConfig::CONFIG["host_os"].to_s, MAX_STRING_LENGTH)
        }
        arch = RbConfig::CONFIG["host_cpu"]
        device["arch"] = clip(arch.to_s, MAX_STRING_LENGTH) if arch && !arch.to_s.empty?
        device
      rescue StandardError
        nil
      end

      def install_at_exit
        return if @at_exit_installed

        @at_exit_installed = true
        at_exit do
          begin
            error = $!
            capture_exception(error) if error.is_a?(Exception) && !error.is_a?(SystemExit)
            flush
          rescue StandardError
            nil
          end
        end
      end

      def normalize_request(request)
        return nil unless request.is_a?(Hash)

        request.each_with_object({}) do |(key, value), out|
          out[key.to_s] = value.is_a?(Hash) ? value.each_with_object({}) { |(k, v), h| h[k.to_s] = v } : value
        end
      end

      def bounded_map(value, limit)
        out = {}
        return out unless value.is_a?(Hash)

        value.each do |name, entry|
          break if out.length >= limit

          name = name.to_s
          next if name.empty? || !entry.is_a?(String)

          out[clip(name, MAX_CONTEXT_KEY_LENGTH)] = clip(entry, MAX_STRING_LENGTH)
        end
        out
      end

      def clip(value, limit)
        value.length > limit ? value[0, limit] : value
      end

      def now_f
        transport = @state&.transport
        transport ? transport.instance_variable_get(:@now).call : Time.now.to_f
      end

      def iso_time(seconds)
        Time.at(seconds).utc.strftime("%Y-%m-%dT%H:%M:%S") + ".000Z"
      end

      def safe_log(log, message)
        (log || ->(m) { warn(m) }).call(message)
      rescue StandardError
        nil
      end
    end
  end
end

require "realuptime/errors/transport"
require "realuptime/errors/rack"
