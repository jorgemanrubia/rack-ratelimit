require 'logger'
require 'time'

module Rack
  # = Ratelimit
  #
  # * Run multiple rate limiters in a single app
  # * Scope each rate limit to certain requests: API, files, GET vs POST, etc.
  # * Apply each rate limit by request characteristics: IP, subdomain, OAuth2 token, etc.
  # * Flexible time window to limit burst traffic vs hourly or daily traffic:
  #     100 requests per 10 sec, 500 req/minute, 10000 req/hour, etc.
  # * Fast, low-overhead implementation using counters per time window:
  #     timeslice = window * ceiling(current time / window)
  #     store.incr(timeslice)
  class Ratelimit
    # Takes a block that classifies requests for rate limiting. Given a
    # Rack env, return a string such as IP address, API token, etc. If the
    # block returns nil, the request won't be rate-limited. If a block is
    # not given, all requests get the same limits.
    #
    # Required configuration:
    #   rate: an array of [max requests, period in seconds]: [500, 5.minutes]
    # and one of
    #   cache: a Dalli::Client instance
    #   redis: a Redis instance
    #   counter: Your own custom counter. Must respond to
    #     `#increment(classification_string, end_of_time_window_epoch_timestamp)`
    #     and return the counter value after increment.
    #
    # Optional configuration:
    #   name: name of the rate limiter. Defaults to 'HTTP'. Used in messages.
    #   status: HTTP response code. Defaults to 429.
    #   conditions: array of procs that take a rack env, all of which must
    #     return true to rate-limit the request.
    #   exceptions: array of procs that take a rack env, any of which may
    #     return true to exclude the request from rate limiting.
    #   logger: responds to #info(message). If provided, the rate limiter
    #     logs the first request that hits the rate limit, but none of the
    #     subsequently blocked requests.
    #   error_message: the message returned in the response body when the rate
    #     limit is exceeded. Defaults to "<name> rate limit exceeded. Please
    #     wait %d seconds then retry your request." The number of seconds
    #     until the end of the rate-limiting window is interpolated into the
    #     message string, but the %d placeholder is optional if you wish to
    #     omit it.
    #
    # Example:
    #
    # Rate-limit bursts of POST/PUT/DELETE by IP address, return 503:
    #   use(Rack::Ratelimit, name: 'POST',
    #     exceptions: ->(env) { env['REQUEST_METHOD'] == 'GET' },
    #     rate:   [50, 10.seconds],
    #     status: 503,
    #     cache:  Dalli::Client.new,
    #     logger: Rails.logger) { |env| Rack::Request.new(env).ip }
    #
    # Rate-limit API traffic by user (set by Rack::Auth::Basic):
    #   use(Rack::Ratelimit, name: 'API',
    #     conditions: ->(env) { env['REMOTE_USER'] },
    #     rate:   [1000, 1.hour],
    #     redis:  Redis.new(ratelimit_redis_config),
    #     logger: Rails.logger) { |env| env['REMOTE_USER'] }
    def initialize(app, options, &classifier)
      @app, @classifier = app, classifier
      @classifier ||= lambda { |env| :request }

      @name = options.fetch(:name, 'HTTP')
      @max, @period = options.fetch(:rate)
      @status = options.fetch(:status, 429)
      @ban_duration = options[:ban_duration]
      @logger = options[:logger]

      @store = build_store(options)
      @error_message = options.fetch(:error_message, "#{@name} rate limit exceeded. Please wait %d seconds then retry your request.")

      @conditions = Array(options[:conditions])
      @exceptions = Array(options[:exceptions])
    end

    # Add a condition that must be met before applying the rate limit.
    # Pass a block or a proc argument that takes a Rack env and returns
    # true if the request should be limited.
    def condition(predicate = nil, &block)
      @conditions << predicate if predicate
      @conditions << block if block_given?
    end

    # Add an exception that excludes requests from the rate limit.
    # Pass a block or a proc argument that takes a Rack env and returns
    # true if the request should be excluded from rate limiting.
    def exception(predicate = nil, &block)
      @exceptions << predicate if predicate
      @exceptions << block if block_given?
    end

    # Apply the rate limiter if none of the exceptions apply and all the
    # conditions are met.
    def apply_rate_limit?(env)
      @exceptions.none? { |e| e.call(env) } && @conditions.all? { |c| c.call(env) }
    end

    # Give subclasses an opportunity to specialize classification.
    def classify(env)
      @classifier.call env
    end

    # Handle a Rack request:
    #   * Check whether the rate limit applies to the request.
    #   * Classify the request by IP, API token, etc.
    #   * Calculate the end of the current time window.
    #   * Increment the counter for this classification and time window.
    #   * If count exceeds limit, return a 429 response.
    #   * If it's the first request that exceeds the limit, log it.
    #   * If the count doesn't exceed the limit, pass through the request.
    def call(env)
      # Accept an optional start-of-request timestamp from the Rack env for
      # upstream timing and for testing.
      now = env.fetch('ratelimit.timestamp', Time.now).to_f

      if @ban_duration && (classification = classify(env)) && @store.banned?(classification)
        build_banned_request_response(now)
      elsif apply_rate_limit?(env) && (classification ||= classify(env))
        handle_rate_limited_request(env, now, classification)
      else
        @app.call(env)
      end
    end

    private

      def build_store(options)
        if options[:counter]
          @logger.info ':counter option has been deprecated. Please, use :store instead.' if @logger
          options[:store] = options[:counter]
        end

        if store = options[:store]
          raise ArgumentError, 'Store must respond to #increment, and also to #ban and #banned? if :ban_duration option is used' unless valid_store?(store)
          store
        elsif cache = options[:cache]
          MemcachedStore.new(cache, @name, @period)
        elsif redis = options[:redis]
          RedisStore.new(redis, @name, @period)
        else
          raise ArgumentError, ':cache, :redis, or :store is required'
        end
      end

      def valid_store?(store)
        store.respond_to?(:increment) && (!@ban_duration || %i[ban! banned?].all? {|method| store.respond_to?(method)})
      end

      def build_banned_request_response(now)
        [@status,
         {'X-Ratelimit' => banned_json(now + @ban_duration),
          'Retry-After' => @ban_duration.to_s},
         [@error_message % @ban_duration]]
      end

      def handle_rate_limited_request(env, now, classification)
        # Increment the request counter.
        epoch = ratelimit_epoch(now)
        count = @store.increment(classification, epoch)
        remaining = @max - count

        # If exceeded, return a 429 Rate Limit Exceeded response.
        if remaining < 0
          handle_limit_exceeded_request(classification, now, epoch, remaining)
        # Otherwise, pass through then add some informational headers.
        else
          handle_request_between_limits(env, epoch, remaining)
        end
      end

      def handle_limit_exceeded_request(classification, now, epoch, remaining)
        @store.ban!(classification, @ban_duration) if @ban_duration

        # Only log the first hit that exceeds the limit.
        if @logger && remaining == -1
          @logger.info '%s: %s exceeded %d request limit for %s %s' %
                           [@name, classification, @max, format_epoch(epoch),  (' (banned)' if @ban_duration)]
        end

        build_limit_exceeded_response(now, epoch, remaining)
      end

      def build_limit_exceeded_response(now, epoch, remaining)
        if @ban_duration
          retry_after = @ban_duration
          retry_epoch = now + @ban_duration
        else
          retry_after = seconds_until_epoch(epoch)
          retry_epoch = epoch
        end

        [@status,
         {'X-Ratelimit' => ratelimit_json(remaining, retry_epoch, @ban_duration),
          'Retry-After' => retry_after.to_s},
         [@error_message % retry_after]]
      end

      def handle_request_between_limits(env, epoch, remaining)
        @app.call(env).tap do |status, headers, body|
          amend_headers headers, 'X-Ratelimit', ratelimit_json(remaining, epoch)
        end
      end

      # Calculate the end of the current rate-limiting window.
      def ratelimit_epoch(timestamp)
        @period * (timestamp / @period).ceil
      end

      def ratelimit_json(remaining, epoch, global = false)
        %({"name":"#{@name}","period":#{@period},"limit":#{@max},"remaining":#{remaining < 0 ? 0 : remaining},"until":"#{format_epoch(epoch)}","global":#{!!global}})
      end

      def banned_json(epoch)
        ratelimit_json(0, epoch, true)
      end

      def format_epoch(epoch)
        Time.at(epoch).utc.xmlschema
      end

    # Clamp negative durations in case we're in a new rate-limiting window.
      def seconds_until_epoch(epoch)
        sec = (epoch - Time.now.to_f).ceil
        sec = 0 if sec < 0
        sec
      end

      def amend_headers(headers, name, value)
        headers[name] = [headers[name], value].compact.join("\n")
      end

      module StoreKeys
        def rate_key(name, classification, epoch)
          'rack-ratelimit/%s/%s/%i' % [name, classification, epoch]
        end

        def ban_key(name, classification)
          'rack-ratelimit/banned/%s/%s' % [name, classification]
        end
      end

      class MemcachedStore
        include StoreKeys

        def initialize(cache, name, period)
          @cache, @name, @period = cache, name, period
        end

        # Increment the request counter and return the current count.
        def increment(classification, epoch)
          key = rate_key(@name, classification, epoch)

          # Try to increment the counter if it's present.
          if count = @cache.incr(key, 1)
            count.to_i

          # If not, add the counter and set expiry.
          elsif @cache.add(key, 1, @period, raw: true)
            1

            # If adding failed, someone else added it concurrently. Increment.
          else
            @cache.incr(key, 1).to_i
          end
        end

        def ban!(classification, ban_duration)
          key = ban_key(@name, classification)
          @cache.add(key, 1, ban_duration, raw: true)
        end

        def banned?(classification)
          @cache.get(ban_key(@name, classification))
        end
      end

      class RedisStore
        include StoreKeys

        def initialize(redis, name, period)
          @redis, @name, @period = redis, name, period
        end

        # Increment the request counter and return the current count.
        def increment(classification, epoch)
          key = rate_key(@name, classification, epoch)
          # Returns [count, expire_ok] response for each multi command.
          # Return the first, the count.
          @redis.multi do |redis|
            redis.incr key
            redis.expire key, @period
          end.first
        end

        def ban!(classification, ban_duration)
          key = ban_key(@name, classification)
          @redis.setex(key, ban_duration, 1)
        end

        def banned?(classification)
          @redis.get(ban_key(@name, classification))
        end
      end
  end
end
