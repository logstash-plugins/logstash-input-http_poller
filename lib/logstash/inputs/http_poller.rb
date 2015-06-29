# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/plugin_mixins/http_client"
require "socket" # for Socket.gethostname
require "manticore"

# Note. This plugin is a WIP! Things will change and break!
#
# Reads from a list of urls and decodes the body of the response with a codec
# The config should look like this:
#
# input {
#   http_poller {
#     urls => {
#       "test1" => "http://localhost:9200"
#     "test2" => "http://localhost:9200/_cluster/health"
#   }
#   request_timeout => 60
#   interval => 10
#   codec => "json"
# }
# }
#
# # This plugin uses metadata, which by default is not serialized
# # You'll need a filter like this to preserve the poller metadata
# # This metadata includes the name, url, response time, headers, and other goodies.
# filter {
#   mutate {
#     add_field => [ "_http_poller_metadata", "%{[@metadata][http_poller]}" ]
#   }
# }
#
#
# output {
#   stdout {
#     codec => rubydebug
#   }
# }

class LogStash::Inputs::HTTP_Poller < LogStash::Inputs::Base
  include LogStash::PluginMixins::HttpClient

  config_name "http_poller"

  default :codec, "json"

  # A Hash of urls in this format : "name" => "url"
  # The name and the url will be passed in the outputed event
  #
  config :urls, :validate => :hash, :required => true

  # How often  (in seconds) the urls will be called
  config :interval, :validate => :number, :required => true

  # If you'd like to work with the request/response metadata
  # Set this value to the name of the field you'd like to store a nested
  # hash of metadata.
  config :metadata_target, :validate => :string, :default => '@metadata'

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

  private
  def run_once(queue)
    @urls.each do |name, url|
      request_async(queue, name, url)
    end

    # TODO: Remove this once our patch to manticore is accepted. The real callback should work
    # Some exceptions are only returned here! There is no callback,
    # for example, if there is a bad port number.
    # https://github.com/cheald/manticore/issues/22
    client.execute!.each_with_index do |resp, i|
      if resp.is_a?(java.lang.Exception) || resp.is_a?(StandardError)
        name = @urls.keys[i]
        url = @urls[name]
        # We can't report the time here because this is as slow as the slowest request
        # This is all temporary code anyway
        handle_failure(queue, name, url, resp, nil)
      end
    end
  end

  private
  def request_async(queue, name, url)
    @logger.debug? && @logger.debug("Fetching URL", :name => name, :url => url)
    started = Time.now
    client.async.get(url).
      on_success {|response| handle_success(queue, name, url, response, Time.now - started)}.
      on_failure {|exception|
      handle_failure(queue, name, url, exception, Time.now - started)
    }
  end

  private
  def handle_success(queue, name, url, response, execution_time)
    @codec.decode(response.body) do |decoded|
      handle_decoded_event(queue, name, url, response, decoded, execution_time)
    end
  end

  private
  def handle_decoded_event(queue, name, url, response, event, execution_time)
    apply_metadata(event, name, url, response, execution_time)
    queue << event
  rescue StandardError, java.lang.Exception => e
    @logger.error? && @logger.error("Error eventifying response!",
                                    :exception => e,
                                    :exception_message => e.message,
                                    :name => name,
                                    :url => url,
                                    :response => response
    )
  end

  private
  def handle_failure(queue, name, url, exception, execution_time)
    event = LogStash::Event.new
    apply_metadata(event, name, url)

    event.tag("_http_request_failure")

    # This is also in the metadata, but we send it anyone because we want this
    # persisted by default, whereas metadata isn't. People don't like mysterious errors
    event["_http_request_failure"] = {
      "url" => url,
      "name" => name,
      "error" => exception.to_s,
      "runtime_seconds" => execution_time
   }

    queue << event
  rescue StandardError, java.lang.Exception => e
      @logger.error? && @logger.error("Cannot read URL or send the error as an event!",
                                      :exception => exception,
                                      :exception_message => exception.message,
                                      :name => name,
                                      :url => url
      )
  end

  private
  def apply_metadata(event, name, url, response=nil, execution_time=nil)
    return unless @metadata_target
    event[@metadata_target] = event_metadata(name, url, response, execution_time)
  end

  private
  def event_metadata(name, url, response=nil, execution_time=nil)
    m = {
        "name" => name,
        "host" => @host,
        "url" => url
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
end
