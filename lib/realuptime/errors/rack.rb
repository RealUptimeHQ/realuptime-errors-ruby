# frozen_string_literal: true

module Realuptime
  module Errors
    # Plain Rack middleware: captures an exception escaping the app below it
    # with the default minimal request context (method, path; the status is
    # unknown mid-flight and omitted rather than guessed), then RE-RAISES.
    # The middleware reports; the server keeps deciding what a 500 looks
    # like. Never headers, never cookies, never bodies: the request capture
    # is the same minimal default the JS and Python SDKs use.
    #
    #   use Realuptime::Errors::RackMiddleware
    #
    # Also reports an exception a downstream framework swallowed into
    # env["rack.exception"] / env["action_dispatch.exception"] (Rails's
    # ShowExceptions sets the latter when it renders its own error page),
    # so a Rails 500 that never propagates still gets captured. The same
    # exception object is reported once, not twice.
    #
    # Zero-dependency: this file never requires "rack"; a Rack app is any
    # object answering call(env).
    class RackMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        response = @app.call(env)
        swallowed = env["action_dispatch.exception"] || env["rack.exception"]
        report(swallowed, env) if swallowed.is_a?(Exception)
        response
      rescue Exception => e # rubocop:disable Lint/RescueException
        report(e, env)
        raise
      end

      # Method + path from a Rack env, nothing else. Shared with the Rails
      # and Sidekiq integrations so every entry point captures identically.
      def self.request_context(env)
        return nil unless env.is_a?(Hash)

        request = {}
        method = env["REQUEST_METHOD"]
        request["method"] = method.to_s if method
        path = env["PATH_INFO"]
        path = "#{env["SCRIPT_NAME"]}#{path}" if env["SCRIPT_NAME"] && !env["SCRIPT_NAME"].to_s.empty?
        request["path"] = path.to_s if path
        request.empty? ? nil : request
      rescue StandardError
        nil
      end

      private

      def report(exc, env)
        return if already_reported?(exc)

        Realuptime::Errors.capture_exception(exc, request: RackMiddleware.request_context(env))
      rescue StandardError
        nil
      end

      def already_reported?(exc)
        return true if exc.instance_variable_get(:@__realuptime_reported)

        exc.instance_variable_set(:@__realuptime_reported, true)
        false
      rescue StandardError
        false
      end
    end
  end
end
