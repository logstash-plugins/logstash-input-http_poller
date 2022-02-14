require "logstash/devutils/rspec/spec_helper"
require "logstash/devutils/rspec/shared_examples"
require 'logstash/inputs/http_poller'
require 'flores/random'
require "timecop"
# Workaround for the bug reported in https://github.com/jruby/jruby/issues/4637
require 'rspec/matchers/built_in/raise_error.rb'
require 'logstash/plugin_mixins/ecs_compatibility_support/spec_helper'

describe LogStash::Inputs::HTTP_Poller do
  let(:metadata_target) { "_http_poller_metadata" }
  let(:queue) { Queue.new }
  let(:default_schedule) {
    { "cron" => "* * * * * UTC" }
  }
  let(:default_name) { "url1 " }
  let(:default_url) { "http://localhost:1827" }
  let(:default_urls) {
    {
      default_name => default_url
    }
  }
  let(:default_opts) {
    {
      "schedule" => default_schedule,
      "urls" => default_urls,
      "codec" => "json",
      "metadata_target" => metadata_target
    }
  }
  let(:klass) { LogStash::Inputs::HTTP_Poller }


  describe "instances" do
    subject { klass.new(default_opts) }

    before do
      subject.register
    end

    describe "#run" do
      it "should setup a scheduler" do
        runner = Thread.new do
          subject.run(double("queue"))
          expect(subject.instance_variable_get("@scheduler")).to be_a_kind_of(Rufus::Scheduler)
        end
        runner.kill
        runner.join
      end
    end

    describe "#run_once" do
      it "should issue an async request for each url" do
        default_urls.each do |name, url|
          normalized_url = subject.send(:normalize_request, url)
          expect(subject).to receive(:request_async).with(queue, name, normalized_url).once
        end

        subject.send(:run_once, queue) # :run_once is a private method
      end
    end

    describe "normalizing a request spec" do
      shared_examples "a normalized request" do
        it "should set the method correctly" do
          expect(normalized.first).to eql(spec_method.to_sym)
        end

        it "should set the options to the URL string" do
          expect(normalized[1]).to eql(spec_url)
        end

        it "should to set additional options correctly" do
          opts = normalized.length > 2 ? normalized[2] : nil
          expect(opts).to eql(spec_opts)
        end
      end

      let(:normalized) { subject.send(:normalize_request, url) }

      describe "a string URL" do
        let(:url) { "http://localhost:3000" }
        let(:spec_url) { url }
        let(:spec_method) { :get }
        let(:spec_opts) { nil }

        include_examples("a normalized request")
      end

      describe "URL specs" do
        context "with basic opts" do
          let(:spec_url) { "http://localhost:3000" }
          let(:spec_method) { "post" }
          let(:spec_opts) { {:"X-Bender" => "Je Suis Napoleon!"} }

          let(:url) do
            {
              "url" => spec_url,
              "method" => spec_method,
            }.merge(Hash[spec_opts.map {|k,v| [k.to_s,v]}])
          end

          include_examples("a normalized request")
        end

        context "missing an URL" do
          let(:url) { {"method" => "get"} }

          it "should raise an error" do
            expect { normalized }.to raise_error(LogStash::ConfigurationError)
          end
        end

        shared_examples "auth" do
          context "with auth enabled but no pass" do
            let(:auth) { {"user" => "foo"} }

            it "should raise an error" do
              expect { normalized }.to raise_error(LogStash::ConfigurationError)
            end
          end

          context "with auth enabled, a path, but no user" do
            let(:url) { {"method" => "get", "auth" => {"password" => "bar"}} }
            it "should raise an error" do
              expect { normalized }.to raise_error(LogStash::ConfigurationError)
            end
          end
          context "with auth enabled correctly" do
            let(:auth) { {"user" => "foo", "password" => "bar"} }

            it "should raise an error" do
              expect { normalized }.not_to raise_error
            end

            it "should properly set the auth parameter" do
              expect(normalized[2][:auth]).to eq({
                                                   :user => auth["user"],
                                                   :pass => auth["password"],
                                                   :eager => true
                                                 })
            end
          end
        end

        # Legacy way of doing things, kept for backwards compat.
        describe "auth with nested auth hash" do
          let(:url) { {"url" => "http://localhost", "method" => "get", "auth" => auth} }

          include_examples("auth")
        end

        # The new 'right' way to do things
        describe "auth with direct auth options" do
          let(:url) { {"url" => "http://localhost", "method" => "get", "user" => auth["user"], "password" => auth["password"]} }

          include_examples("auth")
        end
      end
    end

    describe "#structure_request" do
      it "Should turn a simple request into the expected structured request" do
        expected = {"url" => "http://example.net", "method" => "get"}
        expect(subject.send(:structure_request, ["get", "http://example.net"])).to eql(expected)
      end

      it "should turn a complex request into the expected structured one" do
        headers = {
          "X-Fry" => " Like a balloon, and... something bad happens! "
        }
        expected = {
          "url" => "http://example.net",
          "method" => "get",
          "headers" => headers
        }
        expect(subject.send(:structure_request, ["get", "http://example.net", {"headers" => headers}])).to eql(expected)
      end
    end
  end

  describe "scheduler configuration" do
    context "given 'cron' expression" do
      let(:opts) {
        {
          "schedule" => { "cron" => "* * * * * UTC" },
          "urls" => default_urls,
          "codec" => "json",
          "metadata_target" => metadata_target
        }
      }

      before do
        Timecop.travel(Time.new(2000,1,1,0,0,0,'+00:00'))
        Timecop.scale(60)
      end

      after do
        Timecop.return
      end

      it "should run at the schedule" do
        instance = klass.new(opts)
        instance.register
        queue = Queue.new
        begin
          runner = Thread.new do
            instance.run(queue)
          end
          sleep 3
          try(3) { expect(queue.size).to eq(2) }
        ensure
          instance.stop
          runner.join if runner
        end
      end
    end

    context "given 'at' expression" do
      let(:opts) {
        {
          "schedule" => { "at" => "2000-01-01 00:05:00 +0000"},
          "urls" => default_urls,
          "codec" => "json",
          "metadata_target" => metadata_target
        }
      }

      before do
        Timecop.travel(Time.new(2000,1,1,0,0,0,'+00:00'))
        Timecop.scale(60 * 5)
      end

      after do
        Timecop.return
      end

      it "should run at the schedule" do
        instance = klass.new(opts)
        instance.register

        queue = Queue.new
        runner = Thread.new do
          instance.run(queue)
        end
        sleep 2
        instance.stop
        runner.join
        expect(queue.size).to eq(1)
      end
    end

    context "given 'every' expression" do
      let(:opts) {
        {
          "schedule" => { "every" => "2s"},
          "urls" => default_urls,
          "codec" => "json",
          "metadata_target" => metadata_target
        }
      }
      it "should run at the schedule" do
        instance = klass.new(opts)
        instance.register
        queue = Queue.new
        runner = Thread.new do
          instance.run(queue)
        end
        #T       0123456
        #events  x x x x
        #expects 3 events at T=5
        sleep 5
        instance.stop
        runner.join
        expect(queue.size).to be_between(2, 3)
      end
    end

    context "given 'in' expression" do
      let(:opts) {
        {
          "schedule" => { "in" => "2s"},
          "urls" => default_urls,
          "codec" => "json",
          "metadata_target" => metadata_target
        }
      }
      it "should run at the schedule" do
        instance = klass.new(opts)
        instance.register
        queue = Queue.new
        runner = Thread.new do
          instance.run(queue)
        end
        try(3) do
          sleep(3)
          expect(queue.size).to eq(1)
        end
        instance.stop
        runner.join
        expect(queue.size).to eq(1)
      end
    end
  end

  describe "events", :ecs_compatibility_support, :aggregate_failures do
    ecs_compatibility_matrix(:disabled, :v1, :v8 => :v1) do |ecs_select|
      before do
        allow_any_instance_of(described_class).to receive(:ecs_compatibility).and_return(ecs_compatibility)
      end

      shared_examples("matching metadata") {
        let(:metadata) { event.get(metadata_target) }

        it "should have the correct name" do
          field = ecs_select[disabled: "[#{metadata_target}][name]", v1: "[#{metadata_target}][input][http_poller][request][name]"]
          expect(event.get(field)).to eql(name)
        end

        it "should have the correct request url" do
          if url.is_a?(Hash) # If the url was specified as a complex test the whole thing
            http_client_field = ecs_select[disabled: "[#{metadata_target}][request]",
                                         v1: "[#{metadata_target}][input][http_poller][request][original]"]
            expect(event.get(http_client_field)).to eql(url)
          else # Otherwise we have to make some assumptions
            url_field = ecs_select[disabled: "[#{metadata_target}][request][url]",
                                   v1: "[#{metadata_target}][input][http_poller][request][original][url]"]
            expect(event.get(url_field)).to eql(url)
          end
        end

        it "should have the correct code" do
          expect(event.get(ecs_select[disabled: "[#{metadata_target}][code]",
                                      v1: "[#{metadata_target}][input][http_poller][response][status_code]"]))
            .to eql(code)
        end

        it "should have the correct host" do
          expect(event.get(ecs_select[disabled: "[#{metadata_target}][host]",
                                      v1: "[#{metadata_target}][input][http_poller][request][host][hostname]"]))
            .not_to be_nil
        end
      }

      shared_examples "unprocessable_requests" do
        let(:poller) { LogStash::Inputs::HTTP_Poller.new(settings) }
        subject(:event) {
          poller.send(:run_once, queue)
          queue.pop(true)
        }

        before do
          poller.register
          allow(poller).to receive(:handle_failure).and_call_original
          allow(poller).to receive(:handle_success)
          event # materialize the subject
        end

        it "should enqueue a message" do
          expect(event).to be_a(LogStash::Event)
        end

        it "should enqueue a message with 'http_request_failure' set" do
          if ecs_compatibility == :disabled
            expect(event.get("http_request_failure")).to be_a(Hash)
            expect(event.get("[http_request_failure][runtime_seconds]")).to be_a(Float)
          else
            expect(event.get("http_request_failure")).to be_nil
            expect(event.get("error")).to be_a(Hash)
            expect(event.get("[event][duration]")).to be_a(Integer)
            expect(event.get("[url][full]")).to eq(url)
            expect(event.get("[http][request][method]")).to be_a(String)
            expect(event.get("[host][hostname]")).to be_a(String)
          end
        end

        it "should tag the event with '_http_request_failure'" do
          expect(event.get("tags")).to include('_http_request_failure')
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
          let(:url) { "http://thouetnhoeu89ueoueohtueohtneuohn" }
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

      describe "a valid request and decoded response" do
        let(:payload) { {"a" => 2, "hello" => ["a", "b", "c"]} }
        let(:response_body) { LogStash::Json.dump(payload) }
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
          instance.register
          u = url.is_a?(Hash) ? url["url"] : url # handle both complex specs and simple string URLs
          instance.client.stub(u,
                               :body => response_body,
                               :code => code
          )
          allow(instance).to receive(:decorate)
          instance.send(:run_once, queue)
        end

        it "should have a matching message" do
          expect(event.to_hash).to include(payload)
        end

        it "should decorate the event" do
          expect(instance).to have_received(:decorate).once
        end

        include_examples("matching metadata")

        context "with an empty body" do
          let(:response_body) { "" }
          it "should return an empty event" do
            instance.send(:run_once, queue)
            headers_field = ecs_select[disabled: "[#{metadata_target}][response_headers]",
                                      v1: "[#{metadata_target}][input][http_poller][response][headers]"]
            expect(event.get("#{headers_field}[content-length]")).to eql("0")
          end
        end

        context "with metadata omitted" do
          let(:opts) {
            opts = default_opts.clone
            opts.delete("metadata_target")
            opts
          }

          it "should not have any metadata on the event" do
            instance.send(:run_once, queue)
            expect(event.get(metadata_target)).to be_nil
          end
        end

        context "with a complex URL spec" do
          let(:url) {
            {
              "method" => "get",
              "url" => default_url,
              "headers" => {
                "X-Fry" => "I'm having one of those things, like a headache, with pictures..."
              }
            }
          }
          let(:opts) {
            {
              "schedule" => {
                "cron" => "* * * * * UTC"
              },
              "urls" => {
                default_name => url
              },
              "codec" => "json",
              "metadata_target" => metadata_target
            }
          }

          include_examples("matching metadata")

          it "should have a matching message" do
            expect(event.to_hash).to include(payload)
          end
        end

        context "with a specified target" do
          let(:target) { "mytarget" }
          let(:opts) { default_opts.merge("target" => target) }

          it "should store the event info in the target" do
            # When events go through the pipeline they are java-ified
            # this normalizes the payload to java types
            payload_normalized = LogStash::Json.load(LogStash::Json.dump(payload))
            expect(event.get(target)).to include(payload_normalized)
          end
        end

        context "with default metadata target" do
          let(:metadata_target) { "@metadata" }

          it "should store the metadata info in @metadata" do
            if ecs_compatibility == :disabled
              expect(event.get("[@metadata][response_headers]")).to be_a(Hash)
              expect(event.get("[@metadata][runtime_seconds]")).to be_a(Float)
              expect(event.get("[@metadata][times_retried]")).to eq(0)
              expect(event.get("[@metadata][name]")).to eq(default_name)
              expect(event.get("[@metadata][request]")).to be_a(Hash)
            else
              expect(event.get("[@metadata][input][http_poller][response][headers]")).to be_a(Hash)
              expect(event.get("[@metadata][input][http_poller][response][elapsed_time_ns]")).to be_a(Integer)
              expect(event.get("[@metadata][input][http_poller][request][retry_count]")).to eq(0)
              expect(event.get("[@metadata][input][http_poller][request][name]")).to eq(default_name)
              expect(event.get("[@metadata][input][http_poller][request][original]")).to be_a(Hash)
            end
          end
        end

        context 'using a line codec' do
          let(:opts) do
            default_opts.merge({"codec" => "line"})
          end
          subject(:events) do
            [].tap do |events|
              events << queue.pop until queue.empty?
            end
          end

          context 'when response has a trailing newline' do
            let(:response_body) { "one\ntwo\nthree\nfour\n" }
            it 'emits all events' do
              expect(events.size).to equal(4)
              messages = events.map{|e| e.get('message')}
              expect(messages).to include('one')
              expect(messages).to include('two')
              expect(messages).to include('three')
              expect(messages).to include('four')
            end
          end
          context 'when response has no trailing newline' do
            let(:response_body) { "one\ntwo\nthree\nfour" }
            it 'emits all events' do
              expect(events.size).to equal(4)
              messages = events.map{|e| e.get('message')}
              expect(messages).to include('one')
              expect(messages).to include('two')
              expect(messages).to include('three')
              expect(messages).to include('four')
            end
          end
        end
      end
    end
  end

  describe "stopping" do
    let(:config) { default_opts }
    it_behaves_like "an interruptible input plugin"
  end
end
