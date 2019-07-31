require_relative 'test_helper'
require_relative 'system_test_helper'

module RatelimitSystemTests
  include Rack::Test::Methods

  def teardown
    remove_existing_rate_limit_middleware
  end

  def app
    DummyApp
  end

  def test_rate_limit_works_for_protected_endpoints_during_the_configured_period
    configure_rate_limit_middleware(rate: [2, 1])

    assert_not_rate_limited '/protected'
    assert_not_rate_limited '/protected'
    assert_rate_limited '/protected'
    assert_not_rate_limited '/open'

    sleep 1.5

    assert_not_rate_limited '/protected'
  end

  def test_banning_works_for_all_requests_during_the_ban_period
    configure_rate_limit_middleware(rate: [2, 1], ban_duration: 3)

    assert_not_rate_limited '/protected'
    assert_not_rate_limited '/protected'
    assert_rate_limited '/protected'

    sleep 1.5

    assert_rate_limited '/protected'
    assert_rate_limited '/open'

    sleep 2

    assert_not_rate_limited '/protected'
    assert_not_rate_limited '/open'
  end

  private

    def configure_rate_limit_middleware(options = {})
      options = {
          name: "dummy-limitter-#{SecureRandom.hex(4)}", # random name to prevent collisions across tests
          conditions: ->(env) { env['PATH_INFO'] =~ /\A\/protected/ },
          rate: [2, 1],
          logger: Logger.new(STDOUT)
      }.merge(store_settings).merge(options)

      app.use(Rack::Ratelimit,
              options.merge(store_settings)) {|env| Rack::Request.new(env).ip}
    end

    def remove_existing_rate_limit_middleware
      app.instance_variable_get(:@middleware).delete_if do |middleware|
        middleware.first == Rack::Ratelimit
      end
    end

    def assert_rate_limited(path)
      get path
      assert_equal 429, last_response.status
    end

    def assert_not_rate_limited(path)
      get path
      assert last_response.ok?
    end
end

class MemcachedRatelimitSystemTest < Minitest::Test
  include RatelimitSystemTests

  MEMCACHED_PORT = 11211

  def setup
    @cache = Dalli::Client.new("localhost:#{MEMCACHED_PORT}").tap(&:flush)
    super
  end

  def store_settings
    {cache: @cache}
  end

  def teardown
    super
    @cache.close
  end
end

class RedisRatelimitSystemTest < Minitest::Test
  include RatelimitSystemTests

  def setup
    @redis = Redis.new(:host => 'localhost', :port => 6379, :db => 0).tap(&:flushdb)
    super
  end

  def store_settings
    {redis: @redis}
  end

  def teardown
    super
    @redis.quit
  end
end

