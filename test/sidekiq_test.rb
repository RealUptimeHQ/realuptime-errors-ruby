# frozen_string_literal: true

require_relative "test_helper"
require "realuptime/errors/sidekiq"

class SidekiqIntegrationTest < Minitest::Test
  include SdkTestSupport

  class ChargeWorker; end

  def test_server_middleware_reports_with_worker_queue_and_retry_tags_then_reraises
    setup_sdk
    middleware = Realuptime::Errors::Sidekiq::ServerMiddleware.new
    job = { "class" => "SidekiqIntegrationTest::ChargeWorker", "args" => ["4242424242424242", "secret"], "retry_count" => 2 }
    assert_raises(RuntimeError) do
      middleware.call(ChargeWorker.new, job, "payments") { raise "charge failed" }
    end
    event = @server.events.fetch(0)
    assert_equal "charge failed", event["message"]
    assert_equal ["sidekiq", "SidekiqIntegrationTest::ChargeWorker", "RuntimeError"], event["fingerprint"]
    assert_equal({ "framework" => "sidekiq", "worker" => "SidekiqIntegrationTest::ChargeWorker", "queue" => "payments",
                   "retry_count" => "2" }, event["tags"])
    # Job arguments are never captured.
    refute JSON.generate(event).include?("secret")
  end

  def test_active_job_wrapped_jobs_report_the_wrapped_class
    setup_sdk
    middleware = Realuptime::Errors::Sidekiq::ServerMiddleware.new
    job = { "class" => "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper", "wrapped" => "MailerJob" }
    assert_raises(ArgumentError) { middleware.call(Object.new, job, "default") { raise ArgumentError, "x" } }
    assert_equal "MailerJob", @server.events.fetch(0)["tags"]["worker"]
  end

  def test_successful_job_passes_through
    setup_sdk
    result = Realuptime::Errors::Sidekiq::ServerMiddleware.new.call(ChargeWorker.new, {}, "default") { :ok }
    assert_equal :ok, result
    assert_empty @server.calls
  end

  def test_install_without_sidekiq_raises_a_clear_message
    refute defined?(::Sidekiq), "this suite assumes Sidekiq is not loaded"
    error = assert_raises(RuntimeError) { Realuptime::Errors::Sidekiq.install }
    assert_match(/requires Sidekiq/, error.message)
  end

  def test_install_adds_the_middleware_to_a_sidekiq_shaped_config
    chain = []
    shutdown = []
    config = Object.new
    config.define_singleton_method(:on) { |event, &block| shutdown << [event, block] }
    fake_sidekiq = Module.new
    fake_sidekiq.define_singleton_method(:configure_server) { |&block| block.call(config) }
    Object.const_set(:Sidekiq, fake_sidekiq)
    begin
      # Struct#added is the chain; mimic chain.add by defining it.
      chain.singleton_class.send(:define_method, :add) { |klass| self << klass }
      config.define_singleton_method(:server_middleware) { |&block| block.call(chain) }
      assert Realuptime::Errors::Sidekiq.install
      assert_equal [Realuptime::Errors::Sidekiq::ServerMiddleware], chain
      assert_equal [:shutdown], shutdown.map(&:first)
    ensure
      Object.send(:remove_const, :Sidekiq)
    end
  end
end
