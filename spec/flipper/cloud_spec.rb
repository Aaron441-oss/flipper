require 'helper'
require 'flipper/cloud'
require 'flipper/event_receivers/memory'
require 'flipper/instrumenters/memory'
require 'flipper/adapters/instrumented'
require 'flipper/adapters/pstore'
require 'rack/handler/webrick'

RSpec.describe Flipper::Cloud do
  context "initialize with token" do
    let(:token) { 'asdf' }

    before do
      @instance = described_class.new(token)
      memoized_adapter = @instance.adapter
      @http_adapter = memoized_adapter.adapter
      @http_client = @http_adapter.instance_variable_get('@client')
    end

    it 'returns Flipper::DSL instance' do
      expect(@instance).to be_instance_of(Flipper::DSL)
    end

    it 'configures instance to use http adapter' do
      expect(@http_adapter).to be_instance_of(Flipper::Adapters::Http)
    end

    it 'sets up correct url' do
      uri = @http_client.instance_variable_get('@uri')
      expect(uri.scheme).to eq('https')
      expect(uri.host).to eq('www.featureflipper.com')
      expect(uri.path).to eq('/adapter')
    end

    it 'sets correct token header' do
      headers = @http_client.instance_variable_get('@headers')
      expect(headers['Feature-Flipper-Token']).to eq(token)
    end

    it 'uses noop instrumenter' do
      expect(@instance.instrumenter.instrumenter).to be(Flipper::Instrumenters::Noop)
    end
  end

  context 'initialize with token and options' do
    before do
      @instance = described_class.new('asdf', url: 'https://www.fakeflipper.com/sadpanda')
      memoized_adapter = @instance.adapter
      @http_adapter = memoized_adapter.adapter
      @http_client = @http_adapter.instance_variable_get('@client')
    end

    it 'sets correct url' do
      uri = @http_client.instance_variable_get('@uri')
      expect(uri.scheme).to eq('https')
      expect(uri.host).to eq('www.fakeflipper.com')
      expect(uri.path).to eq('/sadpanda')
    end
  end

  it 'can set instrumenter' do
    instrumenter = Flipper::Instrumenters::Memory.new
    instance = described_class.new('asdf', instrumenter: instrumenter)
    expect(instance.instrumenter.instrumenter).to be(instrumenter)
  end

  it 'allows wrapping adapter with another adapter like the instrumenter' do
    instance = described_class.new('asdf') do |config|
      config.adapter do |adapter|
        Flipper::Adapters::Instrumented.new(adapter)
      end
    end
    # instance.adapter is memoizable adapter instance
    expect(instance.adapter.adapter).to be_instance_of(Flipper::Adapters::Instrumented)
  end

  it 'can set debug_output' do
    expect(Flipper::Adapters::Http::Client).to receive(:new)
      .with(hash_including(debug_output: STDOUT)).at_least(1)
    described_class.new('asdf', debug_output: STDOUT)
  end

  it 'can set read_timeout' do
    expect(Flipper::Adapters::Http::Client).to receive(:new)
      .with(hash_including(read_timeout: 1)).at_least(1)
    described_class.new('asdf', read_timeout: 1)
  end

  it 'can set open_timeout' do
    expect(Flipper::Adapters::Http::Client).to receive(:new)
      .with(hash_including(open_timeout: 1)).at_least(1)
    described_class.new('asdf', open_timeout: 1)
  end

  context 'integration' do
    subject do
      described_class.new("asdf") do |config|
        config.url = "http://localhost:#{FLIPPER_SPEC_API_PORT}"
        config.event_flush_interval = 0.1
      end
    end

    let(:instrumenter) { subject.instrumenter }

    before(:all) do
      @event_receiver = Flipper::EventReceivers::Memory.new
      dir = FlipperRoot.join('tmp').tap(&:mkpath)
      log_path = dir.join('flipper_adapters_http_spec.log')
      @pstore_file = dir.join('flipper.pstore')
      @pstore_file.unlink if @pstore_file.exist?

      api_adapter = Flipper::Adapters::PStore.new(@pstore_file)
      flipper_api = Flipper.new(api_adapter)
      app = Flipper::Api.app(flipper_api, event_receiver: @event_receiver)
      server_options = {
        Port: FLIPPER_SPEC_API_PORT,
        StartCallback: -> { @started = true },
        Logger: WEBrick::Log.new(log_path.to_s, WEBrick::Log::INFO),
        AccessLog: [
          [log_path.open('w'), WEBrick::AccessLog::COMBINED_LOG_FORMAT],
        ],
      }
      @server = WEBrick::HTTPServer.new(server_options)
      @server.mount '/', Rack::Handler::WEBrick, app

      Thread.new { @server.start }
      Timeout.timeout(1) { :wait until @started }
    end

    after(:all) do
      @server.shutdown if @server
    end

    before(:each) do
      @pstore_file.unlink if @pstore_file.exist?
    end

    it 'sends events to event_receiver in batches' do
      actors = Array.new(5) { |i| Flipper::Actor.new("Flipper::Actor;#{i}") }
      subject.enabled?(:foo, actors.sample)
      subject.enabled?(:foo, actors.sample)
      subject.enabled?(:foo, actors.sample)
      subject.enabled?(:foo, actors.sample)
      subject.enabled?(:foo, actors.sample)
      subject.enabled?(:foo, actors.sample)
      instrumenter.shutdown

      expect(@event_receiver.size).to be(1)
      expect(instrumenter.event_queue.size).to be(0)
    end
  end
end
