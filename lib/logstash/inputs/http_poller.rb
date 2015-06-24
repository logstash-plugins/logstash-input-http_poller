# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "socket" # for Socket.gethostname
require "json"
require "manticore"


# Read from a list of url returning some json
# The config should look like this:
#
#     filter {
#       rest {
#               urls     => {"test1" => "http://localhost:11100/management/metrics"
#		                         "test2" => "http://localhost:21100/management/metrics"}
#               timeout  => 60
#               interval => 60
#       }
#    }

class LogStash::Inputs::HTTPPoller < LogStash::Inputs::Base

  config_name "rest"
  milestone 1

  default :codec, "json"

  # A Hash of urls in this format : "name" => "url"
  # The name and the url will be passed in the outputed event
  #
  config :urls, :validate => :hash, :required => true

  # How often  (in seconds) the urls will be called
  config :interval, :validate => :number, :required => true

  # Timeout (in seconds) for the entire request
  config :request_timeout, :validate => :number, :default => 60

  # Timeout (in seconds) to wait for data on the socket. Default is 10s
  config :socket_timeout, :validate => :number, :default => 10

  # Timeout (in seconds) to wait for a connection to be established. Default is 10s
  config :connect_timeout, :validate => :number, :default => 10

  # Should redirects be followed? Defaults to true
  config :follow_redirects, :validate => :boolean, :default => true

  # Max number of concurrent connections. Defaults to 50
  config :pool_max, :validate => :number, :default => 50

  # Max number of concurrent connections to a single host. Defaults to 25
  config :pool_max_per_route, :validate => :number, :default => 25

  # How many times should the client retry a failing URL? Default is 3
  config :automatic_retries, :validate => :number, :default => 3

  # Path to trust store (.jks) containing CA certs
  config :trust_store_path, :validate => :string

  # Password to the trust store if required
  config :trust_store_path, :validate => :string


  public
  def register
    @host = Socket.gethostname.force_encoding(Encoding::UTF_8)

    @logger.info("Registering http-poller Input", :type => @type,
                 :urls => @urls, :interval => @interval, :timeout => @timeout)
  end # def register

  public
  def run(queue)
    Stud.interval(@interval) do
      @urls.each do |name, url|
        client.async.get(url) do |req|
          req.on_success {|response| handle_success(name, url, response)}
          req.on_failure {|exception| handle_failure(name, url, exception)}
        end
      end
      client.execute!
    end
  end

  private
  def handle_success(name, url, response)
    @codec.decode(response) do |event|
      event["name"] = name
      event["host"] = @host
      event["url"] = url
      event["success"] = true
      event["responseCode"] = response.code

      case response.code
        when 200
          event["success"] = true
        else
          event["success"] = false
      end
      decorate(event)
      queue << event
    end
  end

  private
  def handle_failure(name, url, exception)
    @logger.error("Cannot read URL! (#{exception}/#{exception.message})", :name => name, :url => url)
  end



  public
  def client_config
    c = {
      connect_timeout: @connect_timeout,
      socket_timeout: @socket_timeout,
      request_timeout: @request_timeout,
      follow_redirects: @follow_redirects,
      automatic_retries: 3,
      pool_max: @pool_max,
      pool_max_per_route: @pool_max_per_route
    }

    if (@trust_store_path)
      c.merge!(
        truststore: @trust_store_path
      )

      if (@trust_store_password)
        c.merge!(truststore_password: @trust)
      end
    end

    c
  end

  public
  def client
    @client ||= Manticore::Client.new(client_config)
  end
end
