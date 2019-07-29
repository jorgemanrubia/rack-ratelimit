Rack::Ratelimit
===============

* Run multiple rate limiters in a single app
* Scope each rate limit to certain requests: API, files, GET vs POST, etc.
* Apply each rate limit by request characteristics: IP, subdomain, OAuth2 token, etc.
* Option to ban misbehaving clients for a given period of time
* Flexible time window to limit burst traffic vs hourly or daily traffic:
    100 requests per 10 sec, 500 req/minute, 10000 req/hour, etc.
* Fast, low-overhead implementation in memcache using counters for discrete timeslices:

```
timeslice = window * ceiling(current time / window)
memcache.incr(counter for timeslice)
```

Configuration
-------------

Takes a block that classifies requests for rate limiting. Given a
Rack env, return a string such as IP address, API token, etc. If the
block returns nil, the request won't be rate-limited. If a block is
not given, all requests get the same limits.

Required configuration:
* `:rate` - an array of [max requests, period in seconds]: [500, 5.minutes]

and one of
* `:cache` - a Dalli::Client instance
* `:redis` - a Redis instance
* `:store` - Your own custom store. A store is responsible of increasing counters
  and implementing banning logic. Must respond to these methods:

```ruby
# Returns the counter value after increment
def increment(classification_string, end_of_time_window_epoch_timestamp)
end

# Bans the given classification string for the provided duration in seconds
def ban!(classification, ban_duration)
end

# Returns whether the given classification string is banned
def banned?(classification)
end
```

Optional configuration:
* `:name` - name of the rate limiter. Defaults to 'HTTP'. Used in messages.
* `:ban_duration` - period of time in seconds during which clients who exceed the
    rate will be banned (all their requests will be rejected). Defaults to `nil` (no banning).
* `:conditions` - array of procs that take a rack env, all of which must
    return true to rate-limit the request.
* `:exceptions` - array of procs that take a rack env, any of which may
    return true to exclude the request from rate limiting.
* `:logger` - responds to #info(message). If provided, the rate limiter
    logs the first request that hits the rate limit, but none of the
    subsequently blocked requests.
* `:error_message` - the message returned in the response body when the rate
    limit is exceeded. Defaults to "<name> rate limit exceeded. Please
    wait <period> seconds then retry your request."


Examples
--------

Rate-limit bursts of POST/PUT/DELETE requests by IP address

```ruby
use(Rack::Ratelimit, name: 'POST',
  exceptions: ->(env) { env['REQUEST_METHOD'] == 'GET' },
  rate:   [50, 10.seconds],
  cache:  Dalli::Client.new,
  logger: Rails.logger) { |env| Rack::Request.new(env).ip }
```

Rate-limit API traffic by user (set by Rack::Auth::Basic)

```ruby
use(Rack::Ratelimit, name: 'API',
  conditions: ->(env) { env['REMOTE_USER'] },
  rate:   [1000, 1.hour],
  redis:  Redis.new(ratelimit_redis_config),
  logger: Rails.logger) { |env| env['REMOTE_USER'] }
```

Ban IPs that make more than 10 POST requests to `/sessions` in 5 minutes, with the ban lasting 24 hours:

```ruby
use(Rack::Ratelimit, name: 'login_brute_force',
    conditions: ->(env) {env['REQUEST_METHOD'] == 'POST' && env['PATH_INFO'] =~ /\A\/sessions/},
    rate: [10, 5.minutes],
    ban_duration: 24.hours,
    cache: Dalli::Client.new,
    logger: Rails.logger) {|env| Rack::Request.new(env).ip}
```

## Development

### Dependencies

To run the test suite you must have these services installed in your local box:

* [Redis](https://redis.io)
* [Memcached](https://memcached.org)

### Tests

To run the unit test suite:

```bash
rake # or rake test
```

To run the system tests, that exercise the middleware mounted on a Sinatra app:

```bash
rake test:system # or rake test SYSTEM_TESTS=true
```

To run the performance tests:

```bash
rake test:performance # or rake test PERFORMANCE_TESTS=true
```

