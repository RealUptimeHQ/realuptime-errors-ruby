# frozen_string_literal: true

require "realuptime/errors"

module Realuptime
  module Errors
    # Sidekiq server middleware (REA-255). Feature-detected: this file never
    # requires "sidekiq"; `install` only touches ::Sidekiq when it is
    # already loaded and raises a clear message otherwise, the same shape as
    # the Python SDK's Celery hook.
    #
    #   # config/initializers/sidekiq.rb
    #   require "realuptime/errors/sidekiq"
    #   Realuptime::Errors::Sidekiq.install
    #
    # Or add the middleware by hand:
    #
    #   Sidekiq.configure_server do |config|
    #     config.server_middleware { |chain| chain.add Realuptime::Errors::Sidekiq::ServerMiddleware }
    #   end
    #
    # A job's unhandled exception is reported with the worker class as the
    # fingerprint key (so "ArgumentError in ChargeWorker" and "ArgumentError
    # in MailWorker" never collapse into one issue), a framework tag, the
    # worker class and queue as tags, then RE-RAISED so Sidekiq's own retry
    # and dead-set handling is untouched. Job ARGUMENTS are never captured:
    # that is where the customer's users' data lives. Sidekiq's retry count
    # rides as a tag so "first failure" and "24th retry" are tellable apart.
    # Every retry reports its own event; that is the honest count.
    module Sidekiq
      class ServerMiddleware
        def call(worker, job, queue)
          yield
        rescue Exception => e # rubocop:disable Lint/RescueException
          Realuptime::Errors::Sidekiq.report(e, worker, job, queue)
          raise
        end
      end

      def self.report(exc, worker, job, queue)
        worker_name = job.is_a?(Hash) && job["wrapped"] ? job["wrapped"].to_s : worker.class.name.to_s
        tags = { "framework" => "sidekiq", "worker" => worker_name }
        tags["queue"] = queue.to_s if queue
        if job.is_a?(Hash) && job.key?("retry_count")
          tags["retry_count"] = job["retry_count"].to_s
        end
        Realuptime::Errors.capture_exception(
          exc,
          fingerprint: ["sidekiq", worker_name, exc.class.name.to_s],
          tags: tags
        )
      rescue StandardError
        nil
      end

      # Adds the middleware to Sidekiq's server chain. Raises a RuntimeError
      # naming the fix if Sidekiq is not loaded, rather than failing at
      # require time. Idempotent: Sidekiq's chain dedupes by class.
      def self.install
        unless defined?(::Sidekiq) && ::Sidekiq.respond_to?(:configure_server)
          raise "Realuptime::Errors::Sidekiq.install requires Sidekiq to be loaded first (require \"sidekiq\")."
        end

        ::Sidekiq.configure_server do |config|
          config.server_middleware { |chain| chain.add ServerMiddleware }
          # Flush what the worker buffered before the process exits; Sidekiq
          # fires :shutdown on a clean stop (TSTP/TERM), which is where a
          # last in-flight batch would otherwise be lost.
          config.on(:shutdown) { Realuptime::Errors.flush } if config.respond_to?(:on)
        end
        true
      end
    end
  end
end
