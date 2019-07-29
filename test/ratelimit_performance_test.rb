require_relative 'test_helper'
require_relative 'system_test_helper'
require 'benchmark/ips'

module RatelimitPerformanceTest
  BENCHMARK_DURATION = 3
  BENCHMARK_WARMUP = 3

  def setup
    @app = Proc.new { [200, {}, ["hello"]] }
    @redis = Redis.new(:host => 'localhost', :port => 6379, :db => 0).tap(&:flushdb)
  end

  def teardown
    @redis.quit
  end

  def test_baseline_middleware_performance
    baseline_request = Rack::MockRequest.new(@app)

    middleware = build_rack_limit_middleware(@app)
    rate_limit_request = Rack::MockRequest.new(middleware)

    assert_baseline_middleware_performance(baseline_request, rate_limit_request)
  end

  def test_banning_performance_compared_to_just_rate_limit
    only_rate_limit_request = Rack::MockRequest.new(build_rack_limit_middleware(@app))
    banned_request = Rack::MockRequest.new(build_rack_limit_middleware(@app, ban_duration: 2))

    assert_banning_performance_compared_to_just_rate_limit(only_rate_limit_request, banned_request)
  end

  private

  def build_rack_limit_middleware(app, options = {})
    options = {
        name: "performance-#{SecureRandom.hex(4)}",
        conditions: ->(env) { env['PATH_INFO'] =~ /\A\/protected/ },
        rate: [2, 1],
        logger: Logger.new(STDOUT)
    }.merge(store_settings).merge(options)

    Rack::Ratelimit.new(app, options) { |env| 'classified' }
  end

  def assert_slower_by_at_most(threshold_factor, request_configs)
    raise ArgumentError, 'Please provide 2 pairs label => request' if request_configs.length != 2
    baseline_label, baseline_request, target_label, target_request = request_configs.to_a.flatten

    result = Benchmark.ips do |x|
      x.config(time: BENCHMARK_DURATION, warmup: BENCHMARK_WARMUP)
      x.report(target_label) { target_request.get("/protected") }
      x.report(baseline_label) { baseline_request.get("/protected") }
      x.compare!
    end

    baseline_result = result.entries.find { |entry| entry.label == baseline_label }
    rate_limit_result = result.entries.find { |entry| entry.label == target_label }

    times_slower = baseline_result.ips / rate_limit_result.ips
    assert times_slower >= 1, "Actually, '#{baseline_label}' was faster than '#{target_label}' by a factor of #{1 / times_slower}"
    assert times_slower < threshold_factor, "Expecting #{threshold_factor} times slower at most, but got #{times_slower}"
  end
end

class MemcachedRatelimitPerformanceTest < Minitest::Test
  include RatelimitPerformanceTest

  MEMCACHED_PORT = 11211

  def setup
    @cache = Dalli::Client.new("localhost:#{MEMCACHED_PORT}").tap(&:flush)
    super
  end

  def store_settings
    { cache: @cache }
  end

  def teardown
    super
    @cache.close
  end

  private

  def assert_baseline_middleware_performance(baseline_request, rate_limit_request)
    assert_slower_by_at_most 6, 'Baseline' => baseline_request, 'Rate limit' => rate_limit_request
  end

  def assert_banning_performance_compared_to_just_rate_limit(only_rate_limit_request, banned_request)
    assert_slower_by_at_most 1.10, 'Rate limit' => only_rate_limit_request, 'Banning' => banned_request
  end
end

class RedisRatelimitPerformanceTest < Minitest::Test
  include RatelimitPerformanceTest

  def setup
    @redis = Redis.new(:host => 'localhost', :port => 6379, :db => 0).tap(&:flushdb)
    super
  end

  def store_settings
    { redis: @redis }
  end

  def teardown
    super
    @redis.quit
  end

  private

  def assert_baseline_middleware_performance(baseline_request, rate_limit_request)
    assert_slower_by_at_most 7, 'Baseline' => baseline_request, 'Rate limit' => rate_limit_request
  end

  def assert_banning_performance_compared_to_just_rate_limit(only_rate_limit_request, banned_request)
    assert_slower_by_at_most 1.40, 'Banning' => banned_request, 'Rate limit' => only_rate_limit_request
  end
end
