Redis.silence_deprecations = true

#db: ENV['REDIS_DB'],
Redis.current = Redis.new(url: ENV['REDIS_URL'],
                          port: ENV['REDIS_PORT'],
                          
                          ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
