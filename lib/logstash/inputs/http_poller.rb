# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "socket" # for Socket.gethostname
require "json"
require "manticore"

# Note. This plugin is a WIP! Things will change and break!
#
# Reads from a list of urls and decodes the body of the response with a codec
# The config should look like this:
#
#     input {
#       http_poller {
#         urls => {
#           "test1" => "http://localhost:9200"
#		        "test2" => "http://localhost:9200/_cluster/health"
#         }
#         request_timeout => 60
#         interval => 10
#       }
#    }

class LogStash::Inputs::HTTP_Poller < LogStash::Inputs::Base

  config_name "http_poller"

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

  # If you need to use a custom X.509 CA (.pem certs) specify the path to that here
  config :ca_path, :validate => :path

  # If you need to use a custom keystore (.jks) specify that here
  config :truststore_path, :validate => :path

  # Specify the keystore password here.
  # Note, most .jks files created with keytool require a password!
  config :truststore_password, :validate => :string

  # Enable cookie support. With this enabled the client will persist cookies
  # across requests as a normal web browser would. Enabled by default
  config :cookies, :validate => :boolean, :default => true

  # If you'd like to use an HTTP proxy . This supports multiple configuration syntaxes:
  # 1. Proxy host in form: http://proxy.org:1234
  # 2. Proxy host in form: {host => "proxy.org", port => 80, scheme => 'http', user => 'username@host', password => 'password'}
  # 3. Proxy host in form: {url =>  'http://proxy.org:1234', user => 'username@host', password => 'password'}
  config :proxy

  public
  def register
    @host = Socket.gethostname.force_encoding(Encoding::UTF_8)

    @logger.info("Registering http_poller Input", :type => @type,
                 :urls => @urls, :interval => @interval, :timeout => @timeout)
  end # def register

  public
  def run(queue)
    Stud.interval(@interval) do
      run_once(queue)
    end
  end

  def run_once(queue)
    @urls.each do |name, url|
      @logger.debug? && @logger.debug("Will get url '#{name}' '#{url}")
      client.async.get(url).
        on_success {|response| handle_success(queue, name, url, response)}.
        on_failure {|exception| handle_failure(queue, name, url, exception)}
      end
    client.execute!
  end

  private
  def handle_success(queue, name, url, response)
    @codec.decode(response.body) do |decoded|
      event = LogStash::Event.new

      event["name"] = name
      event["host"] = @host
      event["url"] = url
      event["responseCode"] = response.code
      event["message"] = decoded.to_hash
      event["success"] = response.code >= 200 && response.code <= 299

      queue << event
    end
  end

  private
  def handle_failure(queue, name, url, exception)
    @logger.error("Cannot read URL! (#{exception}/#{exception.message})", :name => name, :url => url)
  end

  public
  def client_config
    c = {
      connect_timeout: @connect_timeout,
      socket_timeout: @socket_timeout,
      request_timeout: @request_timeout,
      follow_redirects: @follow_redirects,
      automatic_retries: @automatic_retries,
      pool_max: @pool_max,
      pool_max_per_route: @pool_max_per_route,
      cookies: @cookies,
    }

    if @proxy
      # Symbolize keys if necessary
      c[:proxy] = @proxy.is_a?(Hash) ?
        @proxy.reduce({}) {|memo,(k,v)| memo[k.to_sym] = v; memo} :
        @proxy
    end

    c[:ssl] = {}
    if @ca_path
      c[:ssl][:ca_file] = @ca_path
    end

    if (@truststore_path)
      c.merge!(
        truststore: @trust_store_path
      )

      if (@truststore_password)
        c.merge!(truststore_password: @trust_store_password)
      end
    end

    c
  end

  public
  def client
    @client ||= Manticore::Client.new(client_config)
  end
end
