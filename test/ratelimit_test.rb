require_relative './test_helper'

module RatelimitTests
  WINDOW_DURATION = 10

  BAN_DURATION = 15

  def setup
    @app = ->(env) { [200, {}, []] }
    @logger = Logger.new(@out = StringIO.new)

    @limited = build_ratelimiter(@app, name: :one, rate: [1, WINDOW_DURATION])
    @two_limits = build_ratelimiter(@limited, name: :two, rate: [1, WINDOW_DURATION])
    @banneable = build_ratelimiter(@app, name: :banned, rate: [1, WINDOW_DURATION], ban_duration: BAN_DURATION)
  end

  def test_name_defaults_to_HTTP
    app = build_ratelimiter(@app)
    assert_match '"name":"HTTP"', app.call({})[1]['X-Ratelimit']
  end

  def test_sets_informative_header_when_rate_limit_isnt_exceeded
    status, headers, body = @limited.call({})
    assert_equal 200, status
    assert_match %r({"name":"one","period":10,"limit":1,"remaining":0,"until":".*","global":false}), headers['X-Ratelimit']
    assert_equal [], body
    refute_match '/exceeded/', @out.string
  end

  def test_decrements_rate_limit_header_remaining_count
    app = build_ratelimiter(@app, rate: [3, WINDOW_DURATION])
    remainings = 5.times.map { JSON.parse(app.call({})[1]['X-Ratelimit'])['remaining'] }
    assert_equal [2,1,0,0,0], remainings
  end

  def test_sets_multiple_informative_headers_for_each_rate_limiter
    status, headers, body = @two_limits.call({})
    assert_equal 200, status
    info = headers['X-Ratelimit'].split("\n")
    assert_equal 2, info.size
    assert_match %r({"name":"one","period":10,"limit":1,"remaining":0,"until":".*","global":false}), info.first
    assert_match %r({"name":"two","period":10,"limit":1,"remaining":0,"until":".*","global":false}), info.last
    assert_equal [], body
    refute_match '/exceeded/', @out.string
  end

  def test_responds_with_429_if_request_rate_exceeds_limit
    timestamp = Time.now.to_f
    epoch = WINDOW_DURATION * (timestamp / WINDOW_DURATION).ceil
    retry_after = (epoch - timestamp).ceil

    assert_equal 200, @limited.call('limit-by' => 'key', 'ratelimit.timestamp' => timestamp).first
    status, headers, body = @limited.call('limit-by' => 'key', 'ratelimit.timestamp' => timestamp)
    assert_equal 429, status
    assert_equal retry_after.to_s, headers['Retry-After']
    assert_match '0', headers['X-Ratelimit']
    assert_match %r({"name":"one","period":10,"limit":1,"remaining":0,"until":".*","global":false}), headers['X-Ratelimit']
    assert_equal "one rate limit exceeded. Please wait #{retry_after} seconds then retry your request.", body.first
    assert_match %r{one: classification exceeded 1 request limit for}, @out.string
    refute_match %r{(banned)}, @out.string
  end

  def test_responds_with_429_indicating_ban_duration_the_first_time_a_request_is_banned
    timestamp = Time.now.to_f
    retry_after = BAN_DURATION

    assert_equal 200, @banneable.call('limit-by' => 'key', 'ratelimit.timestamp' => timestamp).first
    status, headers, body = @banneable.call('limit-by' => 'key', 'ratelimit.timestamp' => timestamp)
    assert_equal 429, status
    assert_equal BAN_DURATION, ban_ttl('banned', 'classification')
    assert_equal retry_after.to_s, headers['Retry-After']
    assert_match '0', headers['X-Ratelimit']
    assert_match %r({"name":"banned","period":10,"limit":1,"remaining":0,"until":".*","global":true}), headers['X-Ratelimit']
    assert_equal "banned rate limit exceeded. Please wait #{retry_after} seconds then retry your request.", body.first
    assert_match %r{banned: classification exceeded 1 request limit for}, @out.string
    assert_match %r{(banned)}, @out.string
  end

  def test_responds_with_429_to_every_request_from_banned_clients
    @banneable.condition { |env| env['target'] } # to test that banning works when conditions don't match too

    timestamp = Time.now.to_f
    retry_after = BAN_DURATION

    assert_equal 200, @banneable.call('target' => true, 'ratelimit.timestamp' => timestamp).first
    @banneable.call('target' => true, 'ratelimit.timestamp' => timestamp)
    status, headers, _ = @banneable.call('ratelimit.timestamp' => timestamp)
    assert_match %r({"name":"banned","period":10,"limit":1,"remaining":0,"until":".*","global":true}), headers['X-Ratelimit']
    assert_equal 429, status
    assert_equal retry_after.to_s, headers['Retry-After']
  end

  def test_optional_response_status
    app = build_ratelimiter(@app, status: 503)
    assert_equal 200, app.call('limit-by' => 'key').first
    assert_equal 503, app.call('limit-by' => 'key').first
  end

  def test_doesnt_log_on_subsequent_rate_limited_requests
    assert_equal 200, @limited.call('limit-by' => 'key').first
    assert_equal 429, @limited.call('limit-by' => 'key').first
    out = @out.string.dup
    assert_equal 429, @limited.call('limit-by' => 'key').first
    assert_equal out, @out.string
  end

  def test_classifier_is_optional
    app = build_ratelimiter(@app, no_classifier: true)
    assert_rate_limited app.call({})
  end

  def test_classify_may_be_overridden
    app = build_ratelimiter(@app, no_classifier: true)
    def app.classify(env) env['limit-by'] end
    assert_equal 200, app.call('limit-by' => 'a').first
    assert_equal 200, app.call('limit-by' => 'b').first
  end

  def test_conditions_and_exceptions
    @limited.condition { |env| env['c1'] }
    @limited.condition { |env| env['c2'] }
    @limited.exception { |env| env['e1'] }
    @limited.exception { |env| env['e2'] }

    # Any exceptions exclude the request from rate limiting.
    assert_not_rate_limited @limited.call({ 'c1' => true, 'c2' => true, 'e1' => true })
    assert_not_rate_limited @limited.call({ 'c1' => true, 'c2' => true, 'e2' => true })

    # All conditions must be met to rate-limit the request.
    assert_not_rate_limited @limited.call({ 'c1' => true })
    assert_not_rate_limited @limited.call({ 'c2' => true })

    # If all conditions are met with no exceptions, rate limit.
    assert_rate_limited @limited.call({ 'c1' => true, 'c2' => true })
  end

  def test_conditions_and_exceptions_as_config_options
    app = build_ratelimiter(@app, conditions: ->(env) { env['c1'] })
    assert_rate_limited app.call('c1' => true)
    assert_not_rate_limited app.call('c1' => false)
  end

  def test_skip_rate_limiting_when_classifier_returns_nil
    app = build_ratelimiter(@app) { |env| env['c'] }
    assert_rate_limited app.call('c' => '1')
    assert_not_rate_limited app.call('c' => nil)
  end

  private
    def assert_not_rate_limited(response)
      assert_nil response[1]['X-Ratelimit']
    end

    def assert_rate_limited(response)
      assert !response[1]['X-Ratelimit'].nil?
    end

    def build_ratelimiter(app, options = {}, &block)
      block ||= -> env { 'classification' } unless options.delete(:no_classifier)
      Rack::Ratelimit.new(app, ratelimit_options.merge(options), &block)
    end

    def ratelimit_options
      {rate: [1, WINDOW_DURATION], logger: @logger }
    end
end

class RequiredBackendTest < Minitest::Test
  def test_backend_is_required
    assert_raises ArgumentError do
      Rack::Ratelimit.new(nil, rate: [1,10])
    end
  end
end

DalliClientThatCanCollectTtls = Class.new(Dalli::Client) do
  attr_reader :ttls_by_key

  def add(key, value, ttl = nil, options = nil)
    super.tap do
      @ttls_by_key ||= {}
      @ttls_by_key[key] = ttl
    end
  end
end

class MemcachedRatelimitTest < Minitest::Test
  include RatelimitTests
  include Rack::Ratelimit::StoreKeys

  MEMCACHED_PORT = 11211

  def setup
    @cache = DalliClientThatCanCollectTtls.new("localhost:#{MEMCACHED_PORT}").tap(&:flush)
    super
  end

  def teardown
    super
    @cache.close
  end

  private
    def ratelimit_options
      super.merge cache: @cache
    end

    # Used to check expiration dates for testing purposes
    def ban_ttl(name, classification)
      @cache.ttls_by_key[ban_key(name, classification)]
    end
end

class RedisRatelimitTest < Minitest::Test
  include RatelimitTests
  include Rack::Ratelimit::StoreKeys

  def setup
    @redis = Redis.new(:host => 'localhost', :port => 6379, :db => 0).tap(&:flushdb)
    super
  end

  def teardown
    super
    @redis.quit
  end

  private
    def ratelimit_options
      super.merge redis: @redis
    end

    # Used to check expiration dates for testing purposes
    def ban_ttl(name, classification)
      @redis.ttl(ban_key(name, classification))
    end
end

class CustomStoreRatelimitTest < Minitest::Test
  include RatelimitTests

  def test_raises_error_when_missing_increment_method
    assert_raises ArgumentError do
      Rack::Ratelimit.new(nil, rate: [1,10], store: store_without_methods(:increment))
    end
  end

  def test_raises_error_when_ban_duration_is_used_but_ban_methods_are_missing
    assert_raises ArgumentError do
      Rack::Ratelimit.new(nil, rate: [1,10], ban_duration: 15, store: store_without_methods(:ban!))
      Rack::Ratelimit.new(nil, rate: [1,10], ban_duration: 15, store: store_without_methods(:banned?))
    end
  end

  private
    def ratelimit_options
      super.merge store: (@store = Store.new)
    end

    # Used to check expiration dates for testing purposes
    def ban_ttl(name, classification)
      @store.banned_clients[classification]
    end

    def store_without_methods(*methods_to_remove)
      Store.new.tap do |valid_store|
        methods_to_remove.each do |method|
          valid_store.instance_eval("undef :#{method}")
        end
      end
    end

    class Store
      attr :banned_clients

      def initialize
        @counters = Hash.new do |classifications, name|
          classifications[name] = Hash.new do |timeslices, timestamp|
            timeslices[timestamp] = 0
          end
        end
        @banned_clients = {}
      end

      def increment(classification, timestamp)
        @counters[classification][timestamp] += 1
      end

      def ban!(classification, ban_duration)
        @banned_clients[classification] = ban_duration
      end

      def banned?(classification)
        @banned_clients[classification]
      end
    end
end

class LegacyCustomCounterRateLimitTest < CustomStoreRatelimitTest
  include RatelimitTests

  private
    def ratelimit_options
      super.merge counter: (@store = CustomStoreRatelimitTest::Store.new)
    end
end
