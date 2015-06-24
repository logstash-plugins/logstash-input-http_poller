# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "socket" # for Socket.gethostname
require "json"
require "rest-client"


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

  # Timeout (in seconds) for the rest call
  config :timeout, :validate => :number, :default => 60

  public
  def register
    @host = Socket.gethostname.force_encoding(Encoding::UTF_8)

    @logger.info("Registering rest Input", :type => @type,
                 :urls => @urls, :interval => @interval, :timeout => @timeout)
  end # def register

  public
  def run(queue)
    Stud.interval(@interval) do
      @urls.each do |name, url|
        @logger.debug? && @logger.debug("Checking url ", :name => name , :url => url)
        begin
          RestClient::Request.execute(method: :get, url: url, timeout: timeout, accept: 'json'){ |response, request, result, &block|
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
          }
        rescue
          @logger.error("cannot read URL", :name => name, :url => url)
        end
      end #urls.each
    end #interval loop
  end #def run

end
