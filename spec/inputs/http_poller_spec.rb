require "logstash/devutils/rspec/spec_helper"
require 'logstash/inputs/http_poller'
require 'flores/random'

describe LogStash::Inputs::HTTP_Poller do
  let(:metadata_target) { "_http_poller_metadata" }
  let(:queue) { Queue.new }
  let(:default_interval) { 5 }
  let(:default_name) { "url1 " }
  let(:default_url) { "http://localhost:1827" }
  let(:default_urls) {
    {
      default_name => default_url
    }
  }
  let(:default_opts) {
    {
      "interval" => default_interval,
      "urls" => default_urls,
      "codec" => "json",
      "metadata_target" => metadata_target
    }
  }
  let(:klass) { LogStash::Inputs::HTTP_Poller }

  subject { klass.new(default_opts) }

  describe "#run" do
    it "should run at the specified interval" do
      expect(Stud).to receive(:interval).with(default_interval).once
      subject.run(double("queue"))
    end
  end

  describe "#run_once" do
    it "should issue an async request for each url" do
      default_urls.each { |name, url|
        expect(subject).to receive(:request_async).with(queue, name, url).once
      }

      subject.send(:run_once, queue) # :run_once is a private method
    end
  end

  shared_examples("matching metadata") {
    let(:metadata) { event[metadata_target] }

    it "should have the correct name" do
      expect(metadata["name"]).to eql(name)
    end

    it "should have the correct url" do
      expect(metadata["url"]).to eql(url)
    end

    it "should have the correct code" do
      expect(metadata["code"]).to eql(code)
    end
  }

  shared_examples "unprocessable_requests" do
    let(:poller) { LogStash::Inputs::HTTP_Poller.new(settings) }
    subject(:event) {
      poller.send(:run_once, queue)
      queue.pop(true)
    }

    before do
      allow(poller).to receive(:handle_failure).and_call_original
      allow(poller).to receive(:handle_success)
      event # materialize the subject
    end

    it "should enqueue a message" do
      expect(event).to be_a(LogStash::Event)
    end

    it "should enqueue a message with '_http_request_failure' set" do
      expect(event["_http_request_failure"]).to be_a(Hash)
    end

    it "should tag the event with '_http_request_failure'" do
      expect(event["tags"]).to include('_http_request_failure')
    end

    it "should invoke handle failure exactly once" do
      expect(poller).to have_received(:handle_failure).once
    end

    it "should not invoke handle success at all" do
      expect(poller).not_to have_received(:handle_success)
    end

    include_examples("matching metadata")
  end

  context "with a non responsive server" do
    context "due to a non-existant host" do # Fail with handlers
      let(:name) { default_name }
      let(:url) { "thouetnhoeu89ueoueohtueohtneuohn" }
      let(:code) { nil } # no response expected

      let(:settings) { default_opts.merge("urls" => { name => url}) }

      include_examples("unprocessable_requests")
    end

    context "due to a bogus port number" do # fail with return?
      let(:invalid_port) { Flores::Random.integer(65536..1000000) }

      let(:name) { default_name }
      let(:url) { "http://127.0.0.1:#{invalid_port}" }
      let(:settings) { default_opts.merge("urls" => {name => url}) }
      let(:code) { nil } # No response expected

      include_examples("unprocessable_requests")
    end
  end

  describe "a codec mismatch" do
    let(:instance) { klass.new(default_opts) }
    subject(:qmsg) {
      queue.pop(true)
    }

    before do
      instance.client.stub(default_url,
                           :body => "Definitely not JSON!",
                           :code => 200
      )
      instance.send(:run_once, queue)
    end

    it "should send a _jsonparsefailure" do
      expect(qmsg["tags"]).to include("_jsonparsefailure")
    end
  end

  describe "a valid decoded response" do
    let(:payload) { {"a" => 2, "hello" => ["a", "b", "c"]} }
    let(:opts) { default_opts }
    let(:instance) {
      klass.new(opts)
    }
    let(:name) { default_name }
    let(:url) { default_url }
    let(:code) { 202 }

    subject(:event) {
      queue.pop(true)
    }

    before do
      instance.client.stub(url,
                           :body => LogStash::Json.dump(payload),
                           :code => code
      )
      instance.send(:run_once, queue)
    end

    it "should have a matching message" do
      expect(event.to_hash).to include(payload)
    end

    include_examples("matching metadata")

    context "with metadata omitted" do
      let(:opts) {
        opts = default_opts.clone
        opts.delete("metadata_target")
        opts
      }

      it "should not have any metadata on the event" do
        instance.send(:run_once, queue)
        expect(event[metadata_target]).to be_nil
      end
    end
  end
end
