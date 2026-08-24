# frozen_string_literal: true

require "realuptime/errors"

module Realuptime
  module Errors
    # Rails integration (REA-255). Feature-detected: this file never
    # requires "rails"; the Railtie at the bottom is defined only when
    # ::Rails::Railtie already exists, so requiring this file outside Rails
    # is harmless and the helpers here are testable without it.
    #
    #   # Gemfile
    #   gem "realuptime-errors", require: "realuptime/errors/rails"
    #
    #   # config/initializers/realuptime_errors.rb (or ENV REALUPTIME_ERRORS_DSN)
    #   Rails.application.config.realuptime_errors.dsn = "https://realuptime.io/api/errors/v1/ingest/rue_..."
    #   Rails.application.config.realuptime_errors.release = ENV["GIT_SHA"]
    #
    # What the Railtie installs, all through the ONE capture/scrub/transport
    # path a plain init gives:
    #   - RailsMiddleware at the outermost position of the Rack stack: an
    #     exception that escapes, or one Rails swallowed into its own error
    #     page (action_dispatch.exception), is reported ONCE with method,
    #     path and the matched controller#action as the route template.
    #   - an ActiveJob around_perform hook that reports a job's unhandled
    #     exception with the job class as the fingerprint key and re-raises,
    #     so retry_on / discard_on keep working exactly as before. A job that
    #     retries reports each failed attempt; that is the honest count.
    #   - init itself from config.realuptime_errors / ENV when the app did
    #     not call Realuptime::Errors.init in an initializer.
    module Rails
      FRAMEWORK_TAG = { "framework" => "rails" }.freeze

      # Rack-level context plus the matched controller#action, the grouping
      # key Rails exposes without any user-supplied bytes. path_parameters
      # VALUES (the :id etc.) are never forwarded; only the controller and
      # action names are.
      def self.request_context(env)
        request = RackMiddleware.request_context(env) || {}
        params = env.is_a?(Hash) ? env["action_dispatch.request.path_parameters"] : nil
        if params.is_a?(Hash)
          controller = params[:controller] || params["controller"]
          action = params[:action] || params["action"]
          request["route"] = "#{controller}##{action}" if controller && action
        end
        request.empty? ? nil : request
      rescue StandardError
        nil
      end

      class RailsMiddleware < RackMiddleware
        private

        def report(exc, env)
          return if already_reported?(exc)

          Realuptime::Errors.capture_exception(exc, request: Realuptime::Errors::Rails.request_context(env),
                                                    tags: FRAMEWORK_TAG)
        rescue StandardError
          nil
        end
      end

      # Reports a job's failure and re-raises. Usable without ActiveJob
      # (tests, or a hand-rolled job runner): yield the work.
      def self.perform_reporting(job)
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException
        begin
          job_name = job.class.name.to_s
          Realuptime::Errors.capture_exception(
            e,
            fingerprint: ["active_job", job_name, e.class.name.to_s],
            tags: { "framework" => "active_job", "job" => job_name }
          )
        rescue StandardError
          nil
        end
        raise
      end

      # `include`d into ActiveJob::Base by the Railtie.
      module ActiveJobExtension
        def self.included(base)
          return unless base.respond_to?(:around_perform)

          base.around_perform do |job, block|
            Realuptime::Errors::Rails.perform_reporting(job) { block.call }
          end
        end
      end

      # Resolves init options from config.realuptime_errors (any object
      # answering [] or the dotted accessors) and ENV. Returns nil when no
      # DSN is configured anywhere, so the Railtie stays inert rather than
      # logging on every boot of an app that has not opted in.
      def self.options_from(config, env = ENV, rails_env = nil)
        read = lambda do |key|
          value = nil
          if config.respond_to?(:[])
            value = begin
              config[key]
            rescue StandardError
              nil
            end
          end
          value = config.public_send(key) if value.nil? && config.respond_to?(key)
          value
        end
        dsn = read.call(:dsn) || env["REALUPTIME_ERRORS_DSN"]
        return nil if dsn.nil? || dsn.to_s.empty?

        {
          dsn: dsn.to_s,
          release: read.call(:release) || env["REALUPTIME_RELEASE"],
          environment: read.call(:environment) || rails_env,
          allow_fields: read.call(:allow_fields),
          send_device_info: read.call(:send_device_info).nil? ? true : read.call(:send_device_info)
        }
      end

      if defined?(::Rails::Railtie)
        class Railtie < ::Rails::Railtie
          config.realuptime_errors = ActiveSupport::OrderedOptions.new if defined?(ActiveSupport::OrderedOptions)

          initializer "realuptime_errors.middleware" do |app|
            app.config.middleware.insert_before(0, Realuptime::Errors::Rails::RailsMiddleware)
          end

          initializer "realuptime_errors.active_job" do
            ActiveSupport.on_load(:active_job) { include Realuptime::Errors::Rails::ActiveJobExtension }
          end

          config.after_initialize do |app|
            next if Realuptime::Errors.initialized?

            options = Realuptime::Errors::Rails.options_from(app.config.realuptime_errors, ENV, ::Rails.env.to_s)
            Realuptime::Errors.init(**options) if options
          end
        end
      end
    end
  end
end
