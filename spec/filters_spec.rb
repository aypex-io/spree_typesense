require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense, '#filters' do
  let(:store)    { instance_double('Spree::Store', id: 7, code: 'tkf') }
  let(:provider) { described_class.new(store) }

  def doc(pid, price:, in_stock:)
    { 'id' => "#{pid}_en_USD", 'product_id' => pid, 'locale' => 'en', 'currency' => 'USD',
      'name' => "Product #{pid}", 'status' => 'active', 'in_stock' => in_stock,
      'store_ids' => ['7'], 'discontinue_on' => 0, 'units_sold_count' => 0,
      'price' => price, 'available_on' => '2020-01-01T00:00:00Z',
      'created_at' => '2020-01-01T00:00:00Z' }
  end

  before do
    provider.client.collections[provider.collection_name].delete rescue nil
    provider.ensure_index_settings!
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
    provider.index_batch([
      doc('prod_1', price: 10.0, in_stock: true),
      doc('prod_2', price: 50.0, in_stock: false),
      doc('prod_3', price: 30.0, in_stock: true)
    ])
  end

  subject(:result) { provider.filters(scope: FakeScope.new(%w[prod_1 prod_2 prod_3])) }

  it 'returns a FiltersResult with the total count' do
    expect(result).to be_a(Spree::SearchProvider::FiltersResult)
    expect(result.total_count).to eq(3)
  end

  # REGRESSION: the draft returned bare strings.
  it 'returns sort_options as an array of {id:} hashes' do
    expect(result.sort_options).to eq(
      %w[price -price name -name -available_on available_on best_selling].map { |id| { id: id } }
    )
  end

  # REGRESSION: the draft returned '-created_at'.
  it "uses the literal default_sort 'manual'" do
    expect(result.default_sort).to eq('manual')
  end

  it 'builds a price_range facet spanning the indexed prices' do
    price = result.filters.find { |f| f[:id] == 'price' }
    expect(price).to include(type: 'price_range', currency: 'USD')
    expect(price[:min]).to eq(10.0)
    expect(price[:max]).to eq(50.0)
  end

  # Counts are deliberately unequal (2 in-stock, 1 out-of-stock) so a swapped
  # id<->count pairing in the implementation cannot pass this spec silently.
  it 'builds an availability facet counting both states' do
    avail = result.filters.find { |f| f[:id] == 'availability' }
    expect(avail[:type]).to eq('availability')
    expect(avail[:options]).to contain_exactly(
      { id: 'in_stock', count: 2 }, { id: 'out_of_stock', count: 1 }
    )
  end

  it 'returns an empty-but-valid result when the engine errors' do
    allow(provider).to receive(:execute_search).and_return(nil)
    r = provider.filters(scope: FakeScope.new([]))
    expect(r.filters).to eq([])
    expect(r.total_count).to eq(0)
    expect(r.default_sort).to eq('manual')
  end
end

RSpec.describe Spree::SearchProvider::Typesense::Facets, '.normalize' do
  it 'turns Typesense facet_counts into a field => {value => count} hash' do
    raw = [{ 'field_name' => 'in_stock',
             'counts' => [{ 'value' => 'true', 'count' => 3 }, { 'value' => 'false', 'count' => 1 }] }]
    expect(described_class.normalize(raw)).to eq('in_stock' => { 'true' => 3, 'false' => 1 })
  end
end
