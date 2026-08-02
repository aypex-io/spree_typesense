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
    before do
      unreachable_client = ::Typesense::Client.new(
        nodes: [{ host: 'localhost', port: 1, protocol: 'http' }],
        api_key: 'test-key',
        connection_timeout_seconds: 1,
        num_retries: 0
      )
      allow(provider).to receive(:client).and_return(unreachable_client)
    end

    it 'delegates to the Database provider instead of returning a degraded empty result' do
      database_result = instance_double(Spree::SearchProvider::SearchResult)
      database_provider = instance_double(Spree::SearchProvider::Database, search_and_filter: database_result)
      allow(Spree::SearchProvider::Database).to receive(:new).with(store).and_return(database_provider)

      scope = FakeScope.new([])
      result = provider.search_and_filter(scope: scope, query: 'tongkat', filters: { a: 1 }, sort: '-price', page: 2,
                                            limit: 10)

      expect(result).to eq(database_result)
      expect(database_provider).to have_received(:search_and_filter).with(
        scope: scope, query: 'tongkat', filters: { a: 1 }, sort: '-price', page: 2, limit: 10
      )
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
