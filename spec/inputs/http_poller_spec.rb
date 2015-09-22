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

  describe "instances" do
    subject { klass.new(default_opts) }

    before do
      subject.register
    end

    describe "#run" do
      it "should run at the specified interval" do
        expect(Stud).to receive(:interval).with(default_interval).once
        subject.run(double("queue"))
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

        describe "auth" do
          let(:url) { {"url" => "http://localhost", "method" => "get", "auth" => auth} }

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
              expect(normalized[2][:auth]).to eql({:user => auth["user"], :pass => auth["password"]})
            end
          end
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

  describe "events" do
    shared_examples("matching metadata") {
      let(:metadata) { event[metadata_target] }

      it "should have the correct name" do
        expect(metadata["name"]).to eql(name)
      end

      it "should have the correct request url" do
        if url.is_a?(Hash) # If the url was specified as a complex test the whole thing
          expect(metadata["request"]).to eql(url)
        else # Otherwise we have to make some assumptions
          expect(metadata["request"]["url"]).to eql(url)
        end
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
        poller.register
        allow(poller).to receive(:handle_failure).and_call_original
        allow(poller).to receive(:handle_success)
        event # materialize the subject
      end

      it "should enqueue a message" do
        expect(event).to be_a(LogStash::Event)
      end

      it "should enqueue a message with 'http_request_failure' set" do
        expect(event["http_request_failure"]).to be_a(Hash)
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
                             :body => LogStash::Json.dump(payload),
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
            "interval" => default_interval,
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
          expect(event[target]).to include(payload_normalized)
        end
      end
    end
  end

  describe "stopping" do
    let(:config) { default_opts }
    it_behaves_like "an interruptible input plugin"
  end
end
