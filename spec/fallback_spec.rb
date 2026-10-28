require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense, '#search_and_filter degradation' do
  let(:store)    { instance_double('Spree::Store', id: 1, code: 'tkf') }
  let(:provider) { described_class.new(store) }

  before do
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
  end

  # THE real-failure test. Points the provider's own client at a port nothing
  # is listening on, so `search_with_typesense` drives an actual
  # Faraday::ConnectionFailed through the real Typesense client — not a stub
  # of the method under test. Proves the rescue clause is reachable at all,
  # which a stubbed-raise test alone cannot: execute_search's own internal
  # `rescue ::Typesense::Error, Faraday::Error` would otherwise swallow this
  # exact exception before it ever reaches search_and_filter.
  describe 'when Typesense is genuinely unreachable' do
    let(:unreachable_client) do
      ::Typesense::Client.new(
        nodes: [{ host: 'localhost', port: 1, protocol: 'http' }],
        api_key: 'test-key',
        connection_timeout_seconds: 1,
        num_retries: 0
      )
    end

    before { allow(provider).to receive(:client).and_return(unreachable_client) }

    it 'delegates to the Database provider instead of returning a degraded empty result' do
      database_result = instance_double(Spree::SearchProvider::SearchResult)
      database_provider = instance_double(Spree::SearchProvider::Database, search_and_filter: database_result)
      allow(Spree::SearchProvider::Database).to receive(:new).and_return(database_provider)

      scope = FakeScope.new([])
      result = provider.search_and_filter(scope: scope, query: 'tongkat', filters: { a: 1 }, sort: '-price', page: 2,
                                            limit: 10)

      expect(result).to eq(database_result)
      expect(database_provider).to have_received(:search_and_filter).with(
        scope: scope, query: 'tongkat', filters: { a: 1 }, sort: '-price', page: 2, limit: 10
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

  # Supplementary only: proves the outer rescue clause itself is wired to the
  # right constants and delegates correctly, independent of what triggers it.
  # Must not be the only coverage for this behaviour (see the real-failure
  # spec above).
  describe 'when search_with_typesense raises directly (supplementary)' do
    it 'still delegates to Database on Faraday::ConnectionFailed' do
      allow(provider).to receive(:search_with_typesense).and_raise(Faraday::ConnectionFailed.new('boom'))
      database_result = instance_double(Spree::SearchProvider::SearchResult)
      database_provider = instance_double(Spree::SearchProvider::Database, search_and_filter: database_result)
      allow(Spree::SearchProvider::Database).to receive(:new).and_return(database_provider)

      result = provider.search_and_filter(scope: FakeScope.new([]), query: 'x')

      expect(result).to eq(database_result)
    end

    it 'still delegates to Database on Errno::ECONNREFUSED' do
      allow(provider).to receive(:search_with_typesense).and_raise(Errno::ECONNREFUSED)
      database_result = instance_double(Spree::SearchProvider::SearchResult)
      database_provider = instance_double(Spree::SearchProvider::Database, search_and_filter: database_result)
      allow(Spree::SearchProvider::Database).to receive(:new).and_return(database_provider)

      result = provider.search_and_filter(scope: FakeScope.new([]), query: 'x')

      expect(result).to eq(database_result)
    end
  end
end

RSpec.describe Spree::SearchProvider::Typesense, '#filters degradation' do
  let(:store)    { instance_double('Spree::Store', id: 1, code: 'tkf') }
  let(:provider) { described_class.new(store) }

  before do
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
  end

  # THE real-failure test, same technique as search_and_filter's above:
  # points the provider's own client at a port nothing is listening on, so
  # `filters` drives a genuine Faraday::ConnectionFailed through the real
  # Typesense client rather than a stub of the method under test. `filters`
  # has no Database equivalent to delegate to, so the contract here is that
  # it returns a valid EMPTY FiltersResult instead of raising — asserted
  # field-by-field, not just "did not raise", because a degraded response
  # that doesn't match the success-path shape breaks the storefront filter
  # UI differently than an outage does.
  describe 'when Typesense is genuinely unreachable' do
    before do
      unreachable_client = ::Typesense::Client.new(
        nodes: [{ host: 'localhost', port: 1, protocol: 'http' }],
        api_key: 'test-key',
        connection_timeout_seconds: 1,
        num_retries: 0
      )
      allow(provider).to receive(:client).and_return(unreachable_client)
    end

    it 'returns a valid empty FiltersResult instead of raising' do
      result = provider.filters(scope: FakeScope.new([]), query: 'tongkat')

      expect(result).to be_a(Spree::SearchProvider::FiltersResult)
      expect(result.filters).to eq([])
      expect(result.total_count).to eq(0)
      expect(result.sort_options).to eq(
        %w[price -price name -name -available_on available_on best_selling].map { |id| { id: id, label: nil } }
      )
      expect(result.default_sort).to eq('manual')
    end
  end
end
