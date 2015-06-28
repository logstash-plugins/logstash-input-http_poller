require "logstash/devutils/rspec/spec_helper"
require 'logstash/inputs/http_poller'

describe LogStash::Inputs::HTTP_Poller do
  let(:settings) {
    {
      "interval" => 10,
      "request_timeout" => 1,
      "connect_timeout" => 1,
      "socket_timeout" => 1,
      "automatic_retries" =>1,
      "type" => "something-fancy"
    }
  }
  context "with json codec, when remote server is failing" do
    it "should not add an event" do
      subject = LogStash::Inputs::HTTP_Poller.new(settings.merge({"urls" => {"url1" => "http://mytesturl.mydomain"}}))
      # no stub, and an incorrect domain, this should result in no response.

      logstash_queue = Queue.new
      subject.run_once logstash_queue

      expect(logstash_queue.size).to eq(0)

      subject.teardown
    end

    it "should create an event with an error" do
      subject = LogStash::Inputs::HTTP_Poller.new(settings.merge({"urls" => {"url1" => "http://mytesturl.mydomain"}}))
      subject.client.stub("http://mytesturl.mydomain", body:"not found",  code: 404)

      logstash_queue = Queue.new
      subject.run_once logstash_queue
      event = logstash_queue.pop

      expect(event["responseCode"]).to eq(404)
      expect(event["success"]).to eq(false)
      subject.teardown
    end
  end

  context "with json codec, when remote server responds" do

    it "should have a parse failut with not json" do
      subject = LogStash::Inputs::HTTP_Poller.new(settings.merge({"urls" => {"url1" => "http://mytesturl.mydomain"}}))
      subject.client.stub("http://mytesturl.mydomain", body: "my message is not valid json", code: 200)

      logstash_queue = Queue.new
      subject.run_once logstash_queue
      event = logstash_queue.pop

      expect(event["message"]["tags"]).to include("_jsonparsefailure")
      expect(event["responseCode"]).to eq(200)
      expect(event["success"]).to eq(true)

      subject.teardown
    end

    it "should put the response in a hash" do
      subject = LogStash::Inputs::HTTP_Poller.new(settings.merge({"urls" => {"url1" => "http://mytesturl.mydomain"}}))
      subject.client.stub("http://mytesturl.mydomain", body: "{\"var1\":\"var1-value\"}", code: 200)

      logstash_queue = Queue.new
      subject.run_once logstash_queue
      event = logstash_queue.pop
      expect(event["responseCode"]).to eq(200)
      expect(event["success"]).to eq(true)
      expect(event["message"]["var1"]).to eq("var1-value")
      subject.teardown
    end

    it "should create 2 events" do
      subject = LogStash::Inputs::HTTP_Poller.new(settings.merge({"urls" => {"url1" => "http://mytesturl.mydomain" ,"url2" => "http://mytesturl.mydomain2"}}))
      subject.client.stub("http://mytesturl.mydomain", body: "{\"var1\":\"var1-value\"}", code: 200)
      subject.client.stub("http://mytesturl.mydomain2", body: "{\"var2\":\"var2-value\"}", code: 200)

      logstash_queue = Queue.new
      subject.run_once logstash_queue
      
      expect{ logstash_queue.pop}.not_to raise_error
      event = logstash_queue.pop

      expect(event["responseCode"]).to eq(200)
      expect(event["success"]).to eq(true)
      subject.teardown
    end
  end
end
