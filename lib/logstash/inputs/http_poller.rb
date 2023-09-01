# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/plugin_mixins/http_client"
require "socket" # for Socket.gethostname
require "manticore"
require "logstash/plugin_mixins/ecs_compatibility_support"
require 'logstash/plugin_mixins/ecs_compatibility_support/target_check'
require 'logstash/plugin_mixins/validator_support/field_reference_validation_adapter'
require 'logstash/plugin_mixins/event_support/event_factory_adapter'
require 'logstash/plugin_mixins/scheduler'

class LogStash::Inputs::HTTP_Poller < LogStash::Inputs::Base
  include LogStash::PluginMixins::HttpClient[:with_deprecated => true]
  include LogStash::PluginMixins::ECSCompatibilitySupport(:disabled, :v1, :v8 => :v1)
  include LogStash::PluginMixins::ECSCompatibilitySupport::TargetCheck
  include LogStash::PluginMixins::EventSupport::EventFactoryAdapter

  extend LogStash::PluginMixins::ValidatorSupport::FieldReferenceValidationAdapter

  include LogStash::PluginMixins::Scheduler

  config_name "http_poller"

  default :codec, "json"

  # A Hash of urls in this format : `"name" => "url"`.
  # The name and the url will be passed in the outputed event
  config :urls, :validate => :hash, :required => true

  # Schedule of when to periodically poll from the urls
  # Format: A hash with
  #   + key: "cron" | "every" | "in" | "at"
  #   + value: string
  # Examples:
  #   a) { "every" => "1h" }
  #   b) { "cron" => "* * * * * UTC" }
  # See: rufus/scheduler for details about different schedule options and value string format
  config :schedule, :validate => :hash, :required => true

  # Define the target field for placing the received data. If this setting is omitted, the data will be stored at the root (top level) of the event.
  config :target, :validate => :field_reference

  # If you'd like to work with the request/response metadata.
  # Set this value to the name of the field you'd like to store a nested
  # hash of metadata.
  config :metadata_target, :validate => :string, :default => '@metadata'

  public
  def register
    @host = Socket.gethostname.force_encoding(Encoding::UTF_8)

    setup_ecs_field!
    setup_requests!
  end

  # @overload
  def stop
    close_client
  end

  # @overload
  def close
    close_client
  end

  def close_client
    @logger.debug("closing http client", client: client)
    begin
      client.close # since Manticore 0.9.0 this shuts-down/closes all resources
    rescue => e
      details = { exception: e.class, message: e.message }
      details[:backtrace] = e.backtrace if @logger.debug?
      @logger.warn "failed closing http client", details
    end
  end
  private :close_client

  private
  def setup_requests!
    @requests = Hash[@urls.map {|name, url| [name, normalize_request(url)] }]
  end

  private
  # In the context of ECS, there are two type of events in this plugin, valid HTTP response and failure
  # For a valid HTTP response, `url`, `request_method` and `host` are metadata of request.
  #   The call could retrieve event which contain `[url]`, `[http][request][method]`, `[host][hostname]` data
  #   Therefore, metadata should not write to those fields
  # For a failure, `url`, `request_method` and `host` are primary data of the event because the plugin owns this event,
  #   so it writes to url.*, http.*, host.*
  def setup_ecs_field!
    @request_host_field = ecs_select[disabled: "[#{metadata_target}][host]", v1: "[#{metadata_target}][input][http_poller][request][host][hostname]"]
    @response_code_field = ecs_select[disabled: "[#{metadata_target}][code]", v1: "[#{metadata_target}][input][http_poller][response][status_code]"]
    @response_headers_field = ecs_select[disabled: "[#{metadata_target}][response_headers]", v1: "[#{metadata_target}][input][http_poller][response][headers]"]
    @response_message_field = ecs_select[disabled: "[#{metadata_target}][response_message]", v1: "[#{metadata_target}][input][http_poller][response][status_message]"]
    @response_time_s_field = ecs_select[disabled: "[#{metadata_target}][runtime_seconds]", v1: nil]
    @response_time_ns_field = ecs_select[disabled: nil, v1: "[#{metadata_target}][input][http_poller][response][elapsed_time_ns]"]
    @request_retry_count_field = ecs_select[disabled: "[#{metadata_target}][times_retried]", v1: "[#{metadata_target}][input][http_poller][request][retry_count]"]
    @request_name_field = ecs_select[disabled: "[#{metadata_target}][name]", v1: "[#{metadata_target}][input][http_poller][request][name]"]
    @original_request_field = ecs_select[disabled: "[#{metadata_target}][request]", v1: "[#{metadata_target}][input][http_poller][request][original]"]

    @error_msg_field = ecs_select[disabled: "[http_request_failure][error]", v1: "[error][message]"]
    @stack_trace_field = ecs_select[disabled: "[http_request_failure][backtrace]", v1: "[error][stack_trace]"]
    @fail_original_request_field = ecs_select[disabled: "[http_request_failure][request]", v1: nil]
    @fail_request_name_field = ecs_select[disabled: "[http_request_failure][name]", v1: nil]
    @fail_response_time_s_field = ecs_select[disabled: "[http_request_failure][runtime_seconds]", v1: nil]
    @fail_response_time_ns_field = ecs_select[disabled: nil, v1: "[event][duration]"]
    @fail_request_url_field = ecs_select[disabled: nil, v1: "[url][full]"]
    @fail_request_method_field = ecs_select[disabled: nil, v1: "[http][request][method]"]
    @fail_request_host_field = ecs_select[disabled: nil, v1: "[host][hostname]"]
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

      # Manticore wants auth options that are like {:auth => {:user => u, :pass => p}}
      # We allow that because earlier versions of this plugin documented that as the main way to
      # to do things, but now prefer top level "user", and "password" options
      # So, if the top level user/password are defined they are moved to the :auth key for manticore
      # if those attributes are already in :auth they still need to be transformed to symbols
      auth = spec[:auth]
      user = spec.delete(:user) || (auth && auth["user"])
      password = spec.delete(:password) || (auth && auth["password"])
      
      if user.nil? ^ password.nil?
        raise LogStash::ConfigurationError, "'user' and 'password' must both be specified for input HTTP poller!"
      end

      if user && password
        spec[:auth] = {
          user: user, 
          pass: password,
          eager: true
        } 
      end
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
    setup_schedule(queue)
  end

  def setup_schedule(queue)
    #schedule hash must contain exactly one of the allowed keys
    msg_invalid_schedule = "Invalid config. schedule hash must contain " +
      "exactly one of the following keys - cron, at, every or in"
    raise Logstash::ConfigurationError, msg_invalid_schedule if @schedule.keys.length != 1
    schedule_type = @schedule.keys.first
    schedule_value = @schedule[schedule_type]
    raise LogStash::ConfigurationError, msg_invalid_schedule unless %w(cron every at in).include?(schedule_type)

    opts = schedule_type == "every" ? { first_in: 0.01 } : {}
    scheduler.public_send(schedule_type, schedule_value, opts) { run_once(queue) }
    scheduler.join
  end

  def run_once(queue)
    @requests.each do |name, request|
      # prevent executing a scheduler kick after the plugin has been stop-ed
      # this could easily happen as the scheduler shutdown is not immediate
      return if stop?
      request_async(queue, name, request)
    end

    client.execute! unless stop?
  end

  private
  def request_async(queue, name, request)
    @logger.debug? && @logger.debug("async queueing fetching url", name: name, url: request)
    started = Time.now

    method, *request_opts = request
    client.async.send(method, *request_opts).
      on_success {|response| handle_success(queue, name, request, response, Time.now - started) }.
      on_failure {|exception| handle_failure(queue, name, request, exception, Time.now - started) }
  end

  private
  # time diff in float to nanoseconds
  def to_nanoseconds(time_diff)
    (time_diff * 1000000).to_i
  end

  private
  def handle_success(queue, name, request, response, execution_time)
    @logger.debug? && @logger.debug("success fetching url", name: name, url: request)
    body = response.body
    # If there is a usable response. HEAD requests are `nil` and empty get
    # responses come up as "" which will cause the codec to not yield anything
    if body && body.size > 0
      decode_and_flush(@codec, body) do |decoded|
        event = @target ? targeted_event_factory.new_event(decoded.to_hash) : decoded
        handle_decoded_event(queue, name, request, response, event, execution_time)
      end
    else
      event = event_factory.new_event
      handle_decoded_event(queue, name, request, response, event, execution_time)
    end
  end

  private
  def decode_and_flush(codec, body, &yielder)
    codec.decode(body, &yielder)
    codec.flush(&yielder)
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
    @logger.debug? && @logger.debug("failed fetching url", name: name, url: request)
    event = event_factory.new_event
    event.tag("_http_request_failure")
    apply_metadata(event, name, request, nil, execution_time)
    apply_failure_fields(event, name, request, exception, execution_time)

    queue << event
  rescue StandardError, java.lang.Exception => e
      @logger.error? && @logger.error("Cannot read URL or send the error as an event!",
                                      :exception => e,
                                      :exception_message => e.message,
                                      :exception_backtrace => e.backtrace,
                                      :name => name)

      # If we are running in debug mode we can display more information about the
      # specific request which could give more details about the connection.
      @logger.debug? && @logger.debug("Cannot read URL or send the error as an event!",
                                      :exception => e,
                                      :exception_message => e.message,
                                      :exception_backtrace => e.backtrace,
                                      :name => name,
                                      :url => request)
  end

  private
  def apply_metadata(event, name, request, response, execution_time)
    return unless @metadata_target

    event.set(@request_host_field, @host)
    event.set(@response_time_s_field, execution_time) if @response_time_s_field
    event.set(@response_time_ns_field, to_nanoseconds(execution_time)) if @response_time_ns_field
    event.set(@request_name_field, name)
    event.set(@original_request_field, structure_request(request))

    if response
      event.set(@response_code_field, response.code)
      event.set(@response_headers_field, response.headers)
      event.set(@response_message_field, response.message)
      event.set(@request_retry_count_field, response.times_retried)
    end
  end

  private
  def apply_failure_fields(event, name, request, exception, execution_time)
    # This is also in the metadata, but we send it anyone because we want this
    # persisted by default, whereas metadata isn't. People don't like mysterious errors
    event.set(@fail_original_request_field, structure_request(request)) if @fail_original_request_field
    event.set(@fail_request_name_field, name) if @fail_request_name_field

    method, url, _ = request
    event.set(@fail_request_url_field, url) if @fail_request_url_field
    event.set(@fail_request_method_field, method.to_s) if @fail_request_method_field
    event.set(@fail_request_host_field, @host) if @fail_request_host_field

    event.set(@fail_response_time_s_field, execution_time) if @fail_response_time_s_field
    event.set(@fail_response_time_ns_field, to_nanoseconds(execution_time)) if @fail_response_time_ns_field
    event.set(@error_msg_field, exception.to_s)
    event.set(@stack_trace_field, exception.backtrace)
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
