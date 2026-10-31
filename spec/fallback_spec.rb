require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense, '#search_and_filter degradation' do
  let(:store)    { instance_double('Spree::Store', id: 1, code: 'shop') }
  let(:provider) { described_class.new(store) }

  before do
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
  end

  # THE real-failure test. Points the provider's own search client at a port
  # nothing is listening on, so `search_with_typesense` drives an actual
  # Faraday::ConnectionFailed through the real Typesense client — not a stub
  # of the method under test. Proves the rescue clause is reachable at all,
  # which a stubbed-raise test alone cannot: an earlier rescue inside the
  # search path once swallowed this exact exception before it reached
  # search_and_filter.
  describe 'when Typesense is genuinely unreachable' do
    let(:unreachable_client) do
      ::Typesense::Client.new(
        nodes: [{ host: 'localhost', port: 1, protocol: 'http' }],
        api_key: 'test-key',
        connection_timeout_seconds: 1,
        num_retries: 0
      )
    end

    before { allow(provider).to receive(:search_client).and_return(unreachable_client) }

    it 'delegates to the Database provider instead of returning a degraded empty result' do
      database_result = instance_double(Spree::SearchProvider::SearchResult)
      database_provider = instance_double(Spree::SearchProvider::Database, search_and_filter: database_result)
      allow(Spree::SearchProvider::Database).to receive(:new).and_return(database_provider)

      scope = FakeScope.new([])
      result = provider.search_and_filter(scope: scope, query: 'herbal', filters: { a: 1 }, sort: '-price', page: 2,
                                            limit: 10)

      expect(result).to eq(database_result)
      expect(database_provider).to have_received(:search_and_filter).with(
        scope: scope, query: 'herbal', filters: { a: 1 }, sort: '-price', page: 2, limit: 10
      )
    end

    context 'on Spree 5.x', unless: SpreeTypesense.spree_6? do
      it 'builds the Database provider with the store only, as 5.x providers take' do
        allow(Spree::SearchProvider::Database).to receive(:new).and_call_original

        provider.search_and_filter(scope: FakeScope.new([]), query: 'x') rescue nil

        expect(Spree::SearchProvider::Database).to have_received(:new).with(store)
      end
    end

    # A back-office search (audience: nil) must not degrade into a storefront
    # one: 6.x's Database provider scopes its query and ransack by audience.
    context 'on Spree 6.x', if: SpreeTypesense.spree_6? do
      [:store, nil].each do |audience|
        context "with audience: #{audience.inspect}" do
          let(:provider) { described_class.new(store, audience: audience) }

          it 'builds the Database provider with the same audience' do
            database_provider = instance_double(Spree::SearchProvider::Database, search_and_filter: :database_result)
            allow(Spree::SearchProvider::Database).to receive(:new).and_return(database_provider)

            expect(provider.search_and_filter(scope: FakeScope.new([]), query: 'x')).to eq(:database_result)
            expect(Spree::SearchProvider::Database).to have_received(:new).with(store, audience: audience)
          end
        end
      end

      context 'with a real Database provider' do
        let(:provider) { described_class.new(store, audience: nil) }

        it 'hands it the audience' do
          built = []
          allow(Spree::SearchProvider::Database).to receive(:new).and_wrap_original do |original, *args, **kwargs|
            original.call(*args, **kwargs).tap { |db| built << db }
          end

          # Searching needs a database this suite does not have; building is enough.
          provider.search_and_filter(scope: FakeScope.new([]), query: 'x') rescue nil

          expect(built.map(&:audience)).to eq([nil])
        end
      end
    end
  end

  # Supplementary only: proves the rescue is wired to the right constants and
  # delegates correctly, independent of what triggers it. The failure is
  # raised by the Typesense request itself, the only thing the rescue covers.
  # Must not be the only coverage for this behaviour (see the real-failure
  # spec above).
  describe 'when the Typesense request raises directly (supplementary)' do
    it 'still delegates to Database on Faraday::ConnectionFailed' do
      allow(provider).to receive(:execute_search).and_raise(Faraday::ConnectionFailed.new('boom'))
      database_result = instance_double(Spree::SearchProvider::SearchResult)
      database_provider = instance_double(Spree::SearchProvider::Database, search_and_filter: database_result)
      allow(Spree::SearchProvider::Database).to receive(:new).and_return(database_provider)

      result = provider.search_and_filter(scope: FakeScope.new([]), query: 'x')

      expect(result).to eq(database_result)
    end

    it 'still delegates to Database on Errno::ECONNREFUSED' do
      allow(provider).to receive(:execute_search).and_raise(Errno::ECONNREFUSED)
      database_result = instance_double(Spree::SearchProvider::SearchResult)
      database_provider = instance_double(Spree::SearchProvider::Database, search_and_filter: database_result)
      allow(Spree::SearchProvider::Database).to receive(:new).and_return(database_provider)

      result = provider.search_and_filter(scope: FakeScope.new([]), query: 'x')

      expect(result).to eq(database_result)
    end
  end
end

RSpec.describe Spree::SearchProvider::Typesense, '#filters degradation' do
  let(:store)    { instance_double('Spree::Store', id: 1, code: 'shop') }
  let(:provider) { described_class.new(store) }

  before do
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
  end

  # THE real-failure test, same technique as search_and_filter's above:
  # points the provider's own client at a port nothing is listening on, so
  # `filters` drives a genuine Faraday::ConnectionFailed through the real
  # Typesense client rather than a stub of the method under test. The
  # Database provider computes the same facets from the database, so an
  # outage answers from it rather than with an empty filter sidebar.
  describe 'when Typesense is genuinely unreachable' do
    before do
      unreachable_client = ::Typesense::Client.new(
        nodes: [{ host: 'localhost', port: 1, protocol: 'http' }],
        api_key: 'test-key',
        connection_timeout_seconds: 1,
        num_retries: 0
      )
      allow(provider).to receive(:search_client).and_return(unreachable_client)
    end

    it 'delegates to the Database provider, with the same arguments' do
      database_result = instance_double(Spree::SearchProvider::FiltersResult)
      database_provider = instance_double(Spree::SearchProvider::Database, filters: database_result)
      allow(Spree::SearchProvider::Database).to receive(:new).and_return(database_provider)
      scope = FakeScope.new([])

      result = provider.filters(scope: scope, query: 'herbal', filters: { 'in_stock' => '1' })

      expect(result).to be(database_result)
      expect(database_provider).to have_received(:filters)
        .with(scope: scope, query: 'herbal', filters: { 'in_stock' => '1' })
    end
  end
end

# Any failure to get an answer from Typesense, not just a refused connection,
# answers from the Database provider: correct results, more slowly, beat an
# empty page. Driven through a client double raising what the real client
# raises, so no server is needed.
RSpec.describe Spree::SearchProvider::Typesense, 'when Typesense fails' do
  let(:store)    { instance_double('Spree::Store', id: 1, code: 'shop') }
  let(:scope)    { FakeScope.new([]) }
  let(:database) do
    instance_double(Spree::SearchProvider::Database, search_and_filter: :database_search, filters: :database_filters)
  end
  let(:errors_logged) { [] }
  let(:reported) { [] }

  def new_provider = described_class.new(store).tap { |p| allow(p).to receive_messages(locale: 'en', currency: 'USD') }

  let(:provider) { new_provider }

  def failing_with(error)
    allow(provider).to receive(:search_client).and_return(RecordingTypesenseClient.new { raise error })
  end

  before do
    allow(Spree::SearchProvider::Database).to receive(:new).and_return(database)
    logger = Logger.new(File::NULL)
    allow(logger).to receive(:error) { |msg = nil, &blk| errors_logged << (msg || blk&.call) }
    allow(Rails).to receive(:logger).and_return(logger)
    reporter = Object.new
    allow(reporter).to receive(:report) { |error, severity: nil, **| reported << [error, severity] }
    allow(Rails).to receive(:error).and_return(reporter)
  end

  # A transient failure (a timeout, a 5xx, a lost connection) is reported as a
  # warning. One that will not pass by itself (a rejected query from schema
  # drift, a missing collection, a bad key) is reported as an error, or a
  # broken index could go unnoticed while the Database provider answers.
  {
    'a read timeout' => [Faraday::TimeoutError.new('timed out'), :warning],
    "the client's own timeout error" => [Typesense::Error::TimeoutError.new('timed out'), :warning],
    'a 5xx' => [Typesense::Error::ServerError.new('Internal Server Error'), :warning],
    'a refused connection' => [Faraday::ConnectionFailed.new('Connection refused'), :warning],
    'an unreachable host' => [Errno::EHOSTUNREACH.new, :warning],
    'a reset connection' => [Errno::ECONNRESET.new, :warning],
    'a 400, such as a filter on a field the collection lacks' =>
      [Typesense::Error::RequestMalformed.new('Could not find a filter field named `collection_ids` in the schema.'),
       :error],
    'a missing collection' => [Typesense::Error::ObjectNotFound.new('Not Found'), :error],
    'a rejected API key' => [Typesense::Error::RequestUnauthorized.new('Forbidden'), :error]
  }.each do |description, (error, severity)|
    context "on #{description}" do
      before { failing_with(error) }

      it 'answers a search from the Database provider, with the same arguments' do
        result = provider.search_and_filter(scope: scope, query: 'tea', filters: { 'in_stock' => '1' },
                                            sort: '-price', page: 2, limit: 10)

        expect(result).to eq(:database_search)
        expect(database).to have_received(:search_and_filter)
          .with(scope: scope, query: 'tea', filters: { 'in_stock' => '1' }, sort: '-price', page: 2, limit: 10)
      end

      it 'answers facets from the Database provider, with the same arguments' do
        filters = { 'in_stock' => '1', '_category' => nil }

        expect(provider.filters(scope: scope, query: 'tea', filters: filters)).to eq(:database_filters)
        expect(database).to have_received(:filters).with(scope: scope, query: 'tea', filters: filters)
      end

      it "logs the error and reports it as handled, with severity #{severity}" do
        provider.search_and_filter(scope: scope, query: 'tea')

        expect(errors_logged.join(' ')).to include(error.class.name, 'Database')
        expect(reported).to eq([[error, severity]])
      end
    end
  end

  # Typesense answers multi_search with HTTP 200 and an error per failed
  # search, so a failed facet query raises nothing on its own.
  it 'answers facets from the Database provider when a disjunctive sub-search fails' do
    allow(provider).to receive(:group_option_values_by_type).and_return(1 => %w[ov_red])
    allow(provider).to receive(:search_client).and_return(
      RecordingTypesenseClient.new do |_kind, _params|
        { 'results' => [{ 'found' => 1, 'hits' => [] }, { 'error' => 'Bad filter', 'code' => 400 }] }
      end
    )

    expect(provider.filters(scope: scope, filters: { 'with_option_value_ids' => %w[ov_red] })).to eq(:database_filters)
    expect(errors_logged.join(' ')).to include('Bad filter')
    expect(reported.map(&:last)).to eq([:error])
  end

  # A bug is not an outage: hiding it behind the Database provider would hide
  # it for good.
  it 'does not swallow errors that are not Typesense failing' do
    failing_with(NoMethodError.new('a bug'))

    expect { provider.search_and_filter(scope: scope, query: 'tea') }.to raise_error(NoMethodError, 'a bug')
    expect(database).not_to have_received(:search_and_filter)
  end

  # Only the network errors the Typesense client gives up on count; any other
  # system error is not Typesense being unavailable.
  it 'does not swallow other system errors' do
    failing_with(Errno::EACCES.new)

    expect { provider.search_and_filter(scope: scope, query: 'tea') }.to raise_error(Errno::EACCES)
    expect(database).not_to have_received(:search_and_filter)
  end

  # Only the Typesense request is covered. An error raised around it is not
  # Typesense failing, even when its class could be: it must not be logged as
  # one, nor make the Database provider run again.
  describe 'errors raised around the Typesense request' do
    it 'lets an error from the authorized scope propagate' do
      allow(provider).to receive(:search_client).and_return(RecordingTypesenseClient.new do |_kind, _params|
        { 'found' => 1, 'hits' => [{ 'document' => { 'product_id' => 'prod_1' } }] }
      end)
      allow(scope).to receive(:where).and_raise(Errno::ECONNRESET)

      expect { provider.search_and_filter(scope: scope, query: 'tea') }.to raise_error(Errno::ECONNRESET)
      expect(database).not_to have_received(:search_and_filter)
      expect(errors_logged).to be_empty
    end

    context 'on Spree 6.x', if: SpreeTypesense.spree_6? do
      it 'lets an error from the Database hand-off of a manually sorted listing propagate' do
        allow(database).to receive(:search_and_filter).and_raise(Errno::ECONNREFUSED)

        expect { provider.search_and_filter(scope: scope, filters: { 'in_category' => 'ctg_a' }) }
          .to raise_error(Errno::ECONNREFUSED)
        expect(database).to have_received(:search_and_filter).once
        expect(errors_logged).to be_empty
      end
    end
  end

  # Unconfigured is unavailable too: no 500 from a KeyError on every search.
  describe 'without TYPESENSE_URL or TYPESENSE_API_KEY' do
    before { described_class::UNCONFIGURED_LOGGED.make_false }
    after { described_class::UNCONFIGURED_LOGGED.make_false }

    %w[TYPESENSE_URL TYPESENSE_API_KEY].each do |variable|
      it "answers from the Database provider when #{variable} is not set" do
        with_env(variable => nil) do
          expect(new_provider.search_and_filter(scope: scope, query: 'tea')).to eq(:database_search)
          expect(new_provider.filters(scope: scope)).to eq(:database_filters)
        end
      end
    end

    it 'treats a URL it cannot parse the same way' do
      with_env('TYPESENSE_URL' => 'http://not a host') do
        expect(new_provider.search_and_filter(scope: scope, query: 'tea')).to eq(:database_search)
      end
    end

    it 'logs and reports it once, not on every search' do
      with_env('TYPESENSE_URL' => nil) do
        3.times { new_provider.search_and_filter(scope: scope, query: 'tea') }
      end

      expect(errors_logged.size).to eq(1)
      expect(errors_logged.first).to include('TYPESENSE_URL', 'Database')
      expect(reported.map(&:last)).to eq([:error])
    end

    # Indexing runs in jobs, which should fail loudly and retry.
    it 'still raises when indexing' do
      with_env('TYPESENSE_API_KEY' => nil) do
        expect { new_provider.index_batch([{ 'id' => 'prod_a_en_USD' }]) }
          .to raise_error(Typesense::Error::MissingConfiguration, /TYPESENSE_API_KEY/)
      end
    end
  end

  # The real thing: a node that accepts the connection and never answers.
  # The search client gives up after its timeout, without retrying, and the
  # Database provider answers. The indexing client would have held the
  # request for two of its 5s timeouts.
  describe 'when a node hangs' do
    let!(:server) { TCPServer.new('127.0.0.1', 0) }
    let!(:connections) { Queue.new }
    let!(:acceptor) { Thread.new { loop { connections << server.accept } } }

    after do
      acceptor.kill
      server.close
    end

    it 'gives up after TYPESENSE_SEARCH_TIMEOUT, once, and answers from the Database provider' do
      with_env('TYPESENSE_URL' => "http://127.0.0.1:#{server.addr[1]}", 'TYPESENSE_SEARCH_TIMEOUT' => '0.3') do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect(new_provider.search_and_filter(scope: scope, query: 'tea')).to eq(:database_search)

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.5
      end
      expect(connections.size).to eq(1)
      expect(errors_logged.join(' ')).to include('Faraday::TimeoutError')
    end
  end
end

# A shopper waits on every search, so searches get a client of their own: a
# short timeout and no retry, rather than the indexing client's 5s and one
# retry (about 10s on a hung node). The timeout can be set with
# TYPESENSE_SEARCH_TIMEOUT. Reading the clients' configuration needs no server.
RSpec.describe Spree::SearchProvider::Typesense, 'search client' do
  let(:store)    { instance_double('Spree::Store', id: 1, code: 'shop') }
  let(:provider) { described_class.new(store) }

  def search_config(timeout = nil)
    with_env('TYPESENSE_SEARCH_TIMEOUT' => timeout) { described_class.new(store).search_client.configuration }
  end

  it 'times out after 2 seconds and does not retry' do
    expect(search_config).to have_attributes(connection_timeout_seconds: 2, num_retries: 0)
  end

  it 'takes its timeout from TYPESENSE_SEARCH_TIMEOUT, in seconds' do
    expect(search_config('0.5').connection_timeout_seconds).to eq(0.5)
  end

  %w[abc 0 -1].each do |value|
    it "keeps 2 seconds when TYPESENSE_SEARCH_TIMEOUT is #{value.inspect}" do
      expect(search_config(value).connection_timeout_seconds).to eq(2)
    end
  end

  it 'leaves the indexing client as it was: 5 seconds, one retry' do
    expect(provider.client.configuration).to have_attributes(connection_timeout_seconds: 5, num_retries: 1)
  end

  it 'is the client searches and facets go through' do
    recording = RecordingTypesenseClient.new
    allow(provider).to receive_messages(search_client: recording, locale: 'en', currency: 'USD')
    allow(provider).to receive(:client).and_raise('searched through the indexing client')

    provider.search_and_filter(scope: FakeScope.new([]), query: 'x')
    provider.filters(scope: FakeScope.new([]))

    expect(recording.searches.size).to eq(2)
  end
end
