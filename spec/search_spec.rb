require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense, '#search_and_filter' do
  let(:store)    { instance_double('Spree::Store', id: 7, code: 'tkf') }
  let(:provider) { described_class.new(store) }

  def doc(pid, name:, locale: 'en', currency: 'USD', price: 10.0, available_on: '2020-01-01T00:00:00Z')
    { 'id' => "#{pid}_#{locale}_#{currency}", 'product_id' => pid,
      'locale' => locale, 'currency' => currency, 'name' => name,
      'status' => 'active', 'in_stock' => true, 'store_ids' => ['7'],
      'discontinue_on' => 0, 'units_sold_count' => 0, 'price' => price,
      'available_on' => available_on, 'created_at' => '2020-01-01T00:00:00Z' }
  end

  before do
    provider.client.collections[provider.collection_name].delete rescue nil
    provider.ensure_index_settings!
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
    provider.index_batch([
      doc('prod_1', name: 'Tongkat Ali Extract'),
      doc('prod_2', name: 'Creatine'),
      doc('prod_3', name: 'Tongkat Ali Capsules', locale: 'de', currency: 'EUR')
    ])
  end

  it 'returns a SearchResult of scope-intersected products' do
    result = provider.search_and_filter(scope: FakeScope.new(%w[prod_1 prod_2]), query: 'tongkat')
    expect(result).to be_a(Spree::SearchProvider::SearchResult)
    expect(result.products.map(&:prefixed_id)).to eq(%w[prod_1])
  end

  # THE multi-market test: the German/EUR document must not leak into an en/USD search.
  it 'never returns another market\'s copy of a product' do
    result = provider.search_and_filter(scope: FakeScope.new(%w[prod_1 prod_3]), query: 'tongkat')
    expect(result.products.map(&:prefixed_id)).to eq(%w[prod_1])
  end

  # THE security test.
  it 'never returns a product missing from the authorized scope' do
    result = provider.search_and_filter(scope: FakeScope.new(%w[prod_2]), query: 'tongkat')
    expect(result.products).to be_empty
  end

  it 'returns an empty result when the engine errors' do
    allow(provider).to receive(:execute_search).and_return(nil)
    expect(provider.search_and_filter(scope: FakeScope.new([]), query: 'x').total_count).to eq(0)
  end

  # Proves the available_on_i derived-field fix works end to end against a
  # live server, not just in unit isolation: a future-dated product must not
  # come back from a real search.
  it 'excludes a future-dated product from search results' do
    provider.index_batch([
      doc('prod_9', name: 'Tongkat Ali Future Batch', available_on: 1.year.from_now.iso8601)
    ])

    result = provider.search_and_filter(scope: FakeScope.new(%w[prod_1 prod_9]), query: 'tongkat')

    expect(result.products.map(&:prefixed_id)).to eq(%w[prod_1])
  end
end
