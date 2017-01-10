# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/plugin_mixins/http_client"
require "socket" # for Socket.gethostname
require "manticore"
require "rufus/scheduler"

# This Logstash input plugin allows you to call an HTTP API, decode the output of it into event(s), and
# send them on their merry way. The idea behind this plugins came from a need to read springboot
# metrics endpoint, instead of configuring jmx to monitor my java application memory/gc/ etc.
#
# ==== Example
# Reads from a list of urls and decodes the body of the response with a codec.
# The config should look like this:
#
# [source,ruby]
# ----------------------------------
# input {
#   http_poller {
#     urls => {
#       test1 => "http://localhost:9200"
#       test2 => {
#         # Supports all options supported by ruby's Manticore HTTP client
#         method => get
#         url => "http://localhost:9200/_cluster/health"
#         headers => {
#           Accept => "application/json"
#         }
#         auth => {
#           user => "AzureDiamond"
#           password => "hunter2"
#         }
#       }
#     }
#     request_timeout => 60
#     # Supports "cron", "every", "at" and "in" schedules by rufus scheduler
#     schedule => { cron => "* * * * * UTC"}
#     codec => "json"
#     # A hash of request metadata info (timing, response headers, etc.) will be sent here
#     metadata_target => "http_poller_metadata"
#   }
# }
#
# output {
#   stdout {
#     codec => rubydebug
#   }
# }
# ----------------------------------
#
# Using the HTTP poller with custom a custom CA or self signed cert.
#
# If you have a self signed cert you will need to convert your server's certificate to a valid# `.jks` or `.p12` file. An easy way to do it is to run the following one-liner, substituting your server's URL for the placeholder `MYURL` and `MYPORT`.
#
# [source,ruby]
# ----------------------------------
# openssl s_client -showcerts -connect MYURL:MYPORT </dev/null 2>/dev/null|openssl x509 -outform PEM > downloaded_cert.pem; keytool -import -alias test -file downloaded_cert.pem -keystore downloaded_truststore.jks
# ----------------------------------
#
# The above snippet will create two files `downloaded_cert.pem` and `downloaded_truststore.jks`. You will be prompted to set a password for the `jks` file during this process. To configure logstash use a config like the one that follows.
#
#
# [source,ruby]
# ----------------------------------
#input {
#  http_poller {
#    urls => {
#      myurl => "https://myhostname:1234"
#    }
#    truststore => "/path/to/downloaded_truststore.jks"
#    truststore_password => "mypassword"
#    interval => 30
#  }
#}
# ----------------------------------
#

class LogStash::Inputs::HTTP_Poller < LogStash::Inputs::Base
  include LogStash::PluginMixins::HttpClient

  config_name "http_poller"

  default :codec, "json"

  # A Hash of urls in this format : `"name" => "url"`.
  # The name and the url will be passed in the outputed event
  config :urls, :validate => :hash, :required => true

  # How often (in seconds) the urls will be called
  # DEPRECATED. Use 'schedule' option instead.
  # If both interval and schedule options are specified, interval
  # option takes higher precedence
  config :interval, :validate => :number, :deprecated => true

  # Schedule of when to periodically poll from the urls
  # Format: A hash with
  #   + key: "cron" | "every" | "in" | "at"
  #   + value: string
  # Examples:
  #   a) { "every" => "1h" }
  #   b) { "cron" => "* * * * * UTC" }
  # See: rufus/scheduler for details about different schedule options and value string format
  config :schedule, :validate => :hash

  # Define the target field for placing the received data. If this setting is omitted, the data will be stored at the root (top level) of the event.
  config :target, :validate => :string

  # If you'd like to work with the request/response metadata.
  # Set this value to the name of the field you'd like to store a nested
  # hash of metadata.
  config :metadata_target, :validate => :string, :default => '@metadata'

  public
  Schedule_types = %w(cron every at in)
  def register
    @host = Socket.gethostname.force_encoding(Encoding::UTF_8)

    @logger.info("Registering http_poller Input", :type => @type,
                 :urls => @urls, :interval => @interval, :schedule => @schedule, :timeout => @timeout)

    setup_requests!
  end

  def stop
    Stud.stop!(@interval_thread) if @interval_thread
    @scheduler.stop if @scheduler
  end

  private
  def setup_requests!
    @requests = Hash[@urls.map {|name, url| [name, normalize_request(url)] }]
  end

  private
  def normalize_request(url_or_spec)
    if url_or_spec.is_a?(String)
      res = [:get, url_or_spec]
    elsif url_or_spec.is_a?(Hash)
      # The client will expect keys / values
      spec = Hash[url_or_spec.clone.map {|k,v| [k.to_sym, v] }] # symbolize keys

      # method and url aren't really part of the options, so we pull them out
      method = (spec.delete(:method) || :get).to_sym.downcase
      url = spec.delete(:url)

      # We need these strings to be keywords!
      spec[:auth] = {user: spec[:auth]["user"], pass: spec[:auth]["password"]} if spec[:auth]

      res = [method, url, spec]
    else
      raise LogStash::ConfigurationError, "Invalid URL or request spec: '#{url_or_spec}', expected a String or Hash!"
    end

    validate_request!(url_or_spec, res)
    res
  end

  private
  def validate_request!(url_or_spec, request)
    method, url, spec = request

    raise LogStash::ConfigurationError, "Invalid URL #{url}" unless URI::DEFAULT_PARSER.regexp[:ABS_URI].match(url)

    raise LogStash::ConfigurationError, "No URL provided for request! #{url_or_spec}" unless url
    if spec && spec[:auth]
      if !spec[:auth][:user]
        raise LogStash::ConfigurationError, "Auth was specified, but 'user' was not!"
      end
      if !spec[:auth][:pass]
        raise LogStash::ConfigurationError, "Auth was specified, but 'password' was not!"
      end
    end

    request
  end

  public
  def run(queue)
    #interval or schedule must be provided. Must be exclusively either one. Not neither. Not both.
    raise LogStash::ConfigurationError, "Invalid config. Neither interval nor schedule was specified." \
      unless @interval ||  @schedule
    raise LogStash::ConfigurationError, "Invalid config. Specify only interval or schedule. Not both." \
      if @interval && @schedule

    if @interval
      setup_interval(queue)
    elsif @schedule
      setup_schedule(queue)
    else
      #should not reach here
      raise LogStash::ConfigurationError, "Invalid config. Neither interval nor schedule was specified."
    end
  end

  private
  def setup_interval(queue)
    @interval_thread = Thread.current
    Stud.interval(@interval) do
      run_once(queue)
    end
  end

  def setup_schedule(queue)
    #schedule hash must contain exactly one of the allowed keys
    msg_invalid_schedule = "Invalid config. schedule hash must contain " +
      "exactly one of the following keys - cron, at, every or in"
    raise Logstash::ConfigurationError, msg_invalid_schedule if @schedule.keys.length !=1
    schedule_type = @schedule.keys.first
    schedule_value = @schedule[schedule_type]
    raise LogStash::ConfigurationError, msg_invalid_schedule unless Schedule_types.include?(schedule_type)

    @scheduler = Rufus::Scheduler.new(:max_work_threads => 1)
    #as of v3.0.9, :first_in => :now doesn't work. Use the following workaround instead
    opts = schedule_type == "every" ? { :first_in => 0.01 } : {} 
    @scheduler.send(schedule_type, schedule_value, opts) { run_once(queue) }
    @scheduler.join
  end

  def run_once(queue)
    @requests.each do |name, request|
      request_async(queue, name, request)
    end

    client.execute!
  end

  private
  def request_async(queue, name, request)
    @logger.debug? && @logger.debug("Fetching URL", :name => name, :url => request)
    started = Time.now

    method, *request_opts = request
    client.async.send(method, *request_opts).
      on_success {|response| handle_success(queue, name, request, response, Time.now - started)}.
      on_failure {|exception|
      handle_failure(queue, name, request, exception, Time.now - started)
    }
  end

  private
  def handle_success(queue, name, request, response, execution_time)
    body = response.body
    # If there is a usable response. HEAD requests are `nil` and empty get
    # responses come up as "" which will cause the codec to not yield anything
    if body && body.size > 0
      @codec.decode(body) do |decoded|
        event = @target ? LogStash::Event.new(@target => decoded.to_hash) : decoded
        handle_decoded_event(queue, name, request, response, event, execution_time)
      end
    else
      event = ::LogStash::Event.new
      handle_decoded_event(queue, name, request, response, event, execution_time)
    end
  end

  private
  def handle_decoded_event(queue, name, request, response, event, execution_time)
    apply_metadata(event, name, request, response, execution_time)
    decorate(event)
    queue << event
  rescue StandardError, java.lang.Exception => e
    @logger.error? && @logger.error("Error eventifying response!",
                                    :exception => e,
                                    :exception_message => e.message,
                                    :name => name,
                                    :url => request,
                                    :response => response
    )
  end

  private
  # Beware, on old versions of manticore some uncommon failures are not handled
  def handle_failure(queue, name, request, exception, execution_time)
    event = LogStash::Event.new
    apply_metadata(event, name, request)

    event.tag("_http_request_failure")

    # This is also in the metadata, but we send it anyone because we want this
    # persisted by default, whereas metadata isn't. People don't like mysterious errors
    event.set("http_request_failure", {
      "request" => structure_request(request),
      "name" => name,
      "error" => exception.to_s,
      "backtrace" => exception.backtrace,
      "runtime_seconds" => execution_time
   })

    queue << event
  rescue StandardError, java.lang.Exception => e
      @logger.error? && @logger.error("Cannot read URL or send the error as an event!",
                                      :exception => e,
                                      :exception_message => e.message,
                                      :exception_backtrace => e.backtrace,
                                      :name => name,
                                      :url => request
      )
  end

  private
  def apply_metadata(event, name, request, response=nil, execution_time=nil)
    return unless @metadata_target
    event.set(@metadata_target, event_metadata(name, request, response, execution_time))
  end

  private
  def event_metadata(name, request, response=nil, execution_time=nil)
    m = {
        "name" => name,
        "host" => @host,
        "request" => structure_request(request),
      }

    m["runtime_seconds"] = execution_time

    if response
      m["code"] = response.code
      m["response_headers"] = response.headers
      m["response_message"] = response.message
      m["times_retried"] = response.times_retried
    end

    m
  end

  private
  # Turn [method, url, spec] requests into a hash for friendlier logging / ES indexing
  def structure_request(request)
    method, url, spec = request
    # Flatten everything into the 'spec' hash, also stringify any keys to normalize
    Hash[(spec||{}).merge({
      "method" => method.to_s,
      "url" => url,
    }).map {|k,v| [k.to_s,v] }]
  end
end
