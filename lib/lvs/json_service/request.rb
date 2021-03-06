require 'json'
require 'lvs/json_service/logger'

module LVS
  module JsonService
    module Request
      
      def self.included(base) # :nodoc:
        base.extend ClassMethods    
      end      
      
      module ClassMethods      
      
        def http_request_with_timeout(service, args, options)

          uri = URI.parse(service)

          http = Net::HTTP.new(uri.host, uri.port)
        
          http = Net::HTTP.new(uri.host, uri.port)
          if options[:encrypted] || require_ssl?
            http.use_ssl = true
            # Self-signed certs give streams of "warning: peer certificate won't be verified in this SSL session"
            http.verify_mode = OpenSSL::SSL::VERIFY_NONE 
            LVS::JsonService::Logger.debug "Using SSL"
            if options[:auth_cert]
              LVS::JsonService::Logger.debug "Using Auth"
              http.cert = OpenSSL::X509::Certificate.new(File.read(options[:auth_cert]))
              http.key = OpenSSL::PKey::RSA.new(File.read(options[:auth_key]), options[:auth_key_password])
            end
          end
        
          http.open_timeout = options[:timeout] || 1
          http.read_timeout = options[:timeout] || 1
        
          req = Net::HTTP::Post.new(uri.path)
          req.form_data = { "object_request" => args.to_json }

          retries = options[:retries] || 0

          begin
            retries -= 1          
            response = http.start { |connection| connection.request(req) }
          
          rescue Timeout::Error => e
            if retries >= 0
              LVS::JsonService::Logger.debug(
                "Retrying #{service} due to TimeoutError"
              )
              retry
            end
            raise LVS::JsonService::TimeoutError.new("Backend failed to respond in time", 500, service, args)
                    
          rescue Errno::ECONNREFUSED => e
            if retries >= 0
              LVS::JsonService::Logger.debug(
                "Retrying #{service} due to Errno::ECONNREFUSED"
              )
              sleep(1)  
              retry
            end
            raise LVS::JsonService::BackendUnavailableError.new("Backend unavailable", 500, service, args)
            
          rescue OpenSSL::SSL::SSLError => e
            raise LVS::JsonService::BackendUnavailableError.new("Backend unavailable #{e}", 500, service, args)
            
          end

          if response.is_a?(Net::HTTPNotFound)
            raise LVS::JsonService::NotFoundError.new("404 Found for the service", 404, service, args)
          end

          response
        end

        def run_remote_request(service, args, options = {})
          LVS::JsonService::Logger.debug "Requesting '#{service}' with #{args.to_json}"
          
          if options[:cached_for]
            timing = "CACHED"
            response = Rails.cache.fetch([service, args].cache_key, :expires_in => options[:cached_for]) do
              start = Time.now
              response = http_request_with_timeout(service, args, options)
              timing = ("%.1f" % ((Time.now - start) * 1000)) + "ms"
              response
            end
          else
            start = Time.now
            response = http_request_with_timeout(service, args, options)
            timing = ("%.1f" % ((Time.now - start) * 1000)) + "ms"
          end
          
          if response.body.size < 1024
            LVS::JsonService::Logger.debug "Response (#{timing}): #{response.body.gsub(/\n/, '')}"
          else
            LVS::JsonService::Logger.debug "Response Snippet (#{timing}): #{response.body.gsub(/\n/, '')[0..1024]}"
          end
          result = JSON.parse(response.body)
          if result.is_a?(Hash) && result.has_key?("PCode")
            raise LVS::JsonService::Error.new(result["message"], result["PCode"], service, args, result)
          end
          result
        end
      end
    end
  end
end
