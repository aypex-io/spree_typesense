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

  # Core's storefront scope narrows to the products published on the current
  # channel; so do the listing, its count and its pages here.
  describe 'the current channel' do
    let(:scope) { FakeScope.new(%w[prod_20 prod_21 prod_22 prod_23]) }

    before do
      provider.index_batch([
        doc('prod_20', name: 'Channel Here').merge('channel_ids' => %w[3]),
        doc('prod_21', name: 'Channel Elsewhere').merge('channel_ids' => %w[4]),
        doc('prod_22', name: 'Channel Both').merge('channel_ids' => %w[3 4]),
        doc('prod_23', name: 'Channel Unpublished').merge('channel_ids' => [])
      ])
    end

    it 'returns and counts only the products published on it' do
      allow(Spree::Current).to receive(:channel).and_return(Struct.new(:id).new(3))

      result = provider.search_and_filter(scope: scope, query: 'channel')

      expect(result.products.map(&:prefixed_id)).to contain_exactly('prod_20', 'prod_22')
      expect(result.total_count).to eq(2)
    end

    it 'narrows nothing when there is no current channel' do
      result = provider.search_and_filter(scope: scope, query: 'channel')

      expect(result.total_count).to eq(4)
    end
  end

  # Core's storefront scope keeps a product scheduled to publish later when it
  # is on pre-order (`available(..., include_preorderable: true)`).
  describe 'pre-orders' do
    let(:scope) { FakeScope.new(%w[prod_10 prod_11 prod_12]) }

    before do
      provider.index_batch([
        doc('prod_10', name: 'Launch Edition', available_on: 1.year.from_now.iso8601).merge('preorder' => true),
        doc('prod_11', name: 'Launch Bundle', available_on: 1.year.from_now.iso8601).merge('preorder' => false),
        doc('prod_12', name: 'Launch Classic')
      ])
    end

    it 'returns a future-dated product that is on pre-order, and still excludes one that is not' do
      result = provider.search_and_filter(scope: scope, query: 'launch')

      expect(result.products.map(&:prefixed_id)).to contain_exactly('prod_10', 'prod_12')
      expect(result.total_count).to eq(2)
    end

    it 'counts the pre-order in the facets too' do
      expect(provider.filters(scope: scope, query: 'launch').total_count).to eq(2)
    end

    # Spree 5.5 builds documents with no `preorder` at all. The schema declares
    # it optional, so filtering on it is valid and matches none of them, and
    # the publish date alone decides, as before.
    it 'serves documents built without a preorder field' do
      stored = provider.client.collections[provider.collection_name].documents['prod_12_en_USD'].retrieve
      expect(stored).not_to have_key('preorder')

      result = provider.search_and_filter(scope: scope, query: 'classic')

      expect(result.products.map(&:prefixed_id)).to eq(%w[prod_12])
    end
  end

  # Spree 6.0 whitelists in_collection; a collection listing must not return
  # the whole catalogue, nor count or facet it.
  context 'filtering by collection on Spree 6.x', if: SpreeTypesense.spree_6? do
    before do
      provider.index_batch([
        doc('prod_4', name: 'Tongkat Ali Tea', price: 20.0).merge('collection_ids' => %w[coll_summer]),
        doc('prod_5', name: 'Tongkat Ali Gummies', price: 30.0).merge('collection_ids' => %w[coll_summer coll_new])
      ])
    end

    let(:scope) { FakeScope.new(%w[prod_1 prod_2 prod_4 prod_5]) }

    it 'returns and counts only the products in that collection' do
      result = provider.search_and_filter(scope: scope, filters: { in_collection: 'coll_summer' }, sort: 'price')

      expect(result.products.map(&:prefixed_id)).to eq(%w[prod_4 prod_5])
      expect(result.total_count).to eq(2)
    end

    it 'combines with a query' do
      result = provider.search_and_filter(scope: scope, query: 'gummies', filters: { in_collection: 'coll_summer' })

      expect(result.products.map(&:prefixed_id)).to eq(%w[prod_5])
    end

    it 'limits the facets and their total to the collection' do
      filters = provider.filters(scope: scope, filters: { in_collection: 'coll_new' })

      expect(filters.total_count).to eq(1)
      expect(filters.filters.find { |f| f[:id] == 'price' }).to include(min: 30.0, max: 30.0)
    end
  end
end
