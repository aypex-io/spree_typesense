require 'spec_helper'

# What the provider asks Typesense for, and what it does with the answer,
# with a recording client in place of the server. What Typesense does with
# the same requests is pinned against the real server in search_spec.rb.
RSpec.describe Spree::SearchProvider::Typesense, 'search requests' do
  let(:store)    { instance_double('Spree::Store', id: 7, code: 'shop') }
  let(:provider) { described_class.new(store) }
  let(:client)   { RecordingTypesenseClient.new }

  def hits(*product_ids)
    { 'found' => product_ids.size, 'hits' => product_ids.map { |pid| { 'document' => { 'product_id' => pid } } },
      'facet_counts' => [] }
  end

  before do
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
    allow(provider).to receive(:client).and_return(client)
  end

  # Core's storefront scope narrows to the current channel's publications
  # (`for_channel(Spree::Current.channel)`), as Meilisearch's filter does.
  # Without it the listing would count and paginate products the channel
  # does not sell.
  describe 'the current channel' do
    let(:channel) { Struct.new(:id).new(3) }

    it 'scopes searches to it' do
      allow(Spree::Current).to receive(:channel).and_return(channel)

      provider.search_and_filter(scope: FakeScope.new([]), query: 'x')

      expect(client.searches.sole[:filter_by]).to include('channel_ids:=`3`')
    end

    it 'scopes facets to it' do
      allow(Spree::Current).to receive(:channel).and_return(channel)

      provider.filters(scope: FakeScope.new([]))

      expect(client.searches.sole[:filter_by]).to include('channel_ids:=`3`')
    end

    it 'adds no channel filter when there is no current channel' do
      provider.search_and_filter(scope: FakeScope.new([]), query: 'x')

      expect(client.searches.sole[:filter_by]).not_to include('channel_ids')
    end
  end

  # The filters endpoint advertises the sorts a listing offers and which one
  # it starts on, as the Database provider's FiltersAggregator does.
  describe '#filters sort options and default sort' do
    def collection(sort_order) = Struct.new(:sort_order).new(sort_order)

    it "offers 'manual', as the Database provider does, ahead of the field sorts" do
      expect(provider.filters(scope: FakeScope.new([])).sort_options).to eq(
        %w[manual price -price name -name -available_on available_on best_selling].map { |id| { id: id, label: nil } }
      )
    end

    it "defaults to 'manual' outside a collection" do
      expect(provider.filters(scope: FakeScope.new([])).default_sort).to eq('manual')
    end

    {
      'price asc' => 'price', 'price desc' => '-price', 'name desc' => '-name', 'available_on desc' => '-available_on',
      'best_selling' => 'best_selling', 'manual' => 'manual', nil => 'manual'
    }.each do |sort_order, api_sort|
      it "defaults a collection sorted #{sort_order.inspect} to #{api_sort.inspect}" do
        result = provider.filters(scope: FakeScope.new([]), filters: { '_collection' => collection(sort_order) })

        expect(result.default_sort).to eq(api_sort)
      end
    end

    it 'reads a symbol-keyed _collection too' do
      result = provider.filters(scope: FakeScope.new([]), filters: { _collection: collection('price desc') })

      expect(result.default_sort).to eq('-price')
    end
  end

  # Spree 6's Database provider orders a single category or collection by the
  # merchant's positions when the sort is 'manual', or omitted there. The
  # index carries no positions, so those listings go to the Database provider.
  describe '#search_and_filter on a manually sorted listing' do
    let(:database_result) { instance_double(Spree::SearchProvider::SearchResult) }
    let(:database) { instance_double(Spree::SearchProvider::Database, search_and_filter: database_result) }
    let(:scope) { FakeScope.new([]) }

    before { allow(Spree::SearchProvider::Database).to receive(:new).and_return(database) }

    def search(**args) = provider.search_and_filter(scope: scope, page: 2, limit: 10, **args)

    context 'on Spree 6.x', if: SpreeTypesense.spree_6? do
      [
        [{ 'in_category' => 'ctg_a' }, nil],
        [{ 'in_category' => 'ctg_a' }, ''],
        [{ 'in_collection' => 'coll_a' }, nil],
        [{ 'in_collection' => 'coll_a' }, 'manual'],
        [{ in_collection: 'coll_a', 'price_gte' => '5' }, 'manual']
      ].each do |filters, sort|
        it "hands #{filters.inspect} sorted #{sort.inspect} to the Database provider, unchanged" do
          expect(search(filters: filters, sort: sort)).to be(database_result)
          expect(database).to have_received(:search_and_filter)
            .with(scope: scope, query: nil, filters: filters, sort: sort, page: 2, limit: 10)
          expect(client.searches).to be_empty
        end
      end

      it 'builds the Database provider with this provider\'s audience' do
        provider = described_class.new(store, audience: nil)
        allow(provider).to receive(:client).and_return(client)

        provider.search_and_filter(scope: scope, filters: { 'in_category' => 'ctg_a' })

        expect(Spree::SearchProvider::Database).to have_received(:new).with(store, audience: nil)
      end
    end

    # Each of these stays on Typesense: a text query ranks by relevance, a
    # field sort is Typesense's to apply, and without one grouping 'manual'
    # has no positions to follow even in the Database provider.
    [
      ['a text query', { query: 'tea', filters: { 'in_collection' => 'coll_a' }, sort: 'manual' }],
      ['a field sort', { filters: { 'in_collection' => 'coll_a' }, sort: 'price' }],
      ["'manual' with no grouping", { sort: 'manual' }],
      ['several categories', { filters: { 'in_categories' => %w[ctg_a ctg_b] } }],
      ['an invalid grouping id', { filters: { 'in_category' => 'ctg_a || x' } }]
    ].each do |description, args|
      it "keeps #{description} on Typesense" do
        search(**args)

        expect(database).not_to have_received(:search_and_filter)
        expect(client.searches.size).to eq(1)
      end
    end

    it 'leaves the order to relevance for a text query under a manual sort' do
      search(query: 'tea', filters: { 'in_collection' => 'coll_a' }, sort: 'manual')

      expect(client.searches.sole).not_to have_key(:sort_by)
    end

    # Spree 5's Database provider applies no position order through this API,
    # so handing it a listing would only lose Typesense's ranking.
    context 'on Spree 5.x', unless: SpreeTypesense.spree_6? do
      it 'keeps a category listing on Typesense' do
        search(filters: { 'in_category' => 'txn_a' })

        expect(database).not_to have_received(:search_and_filter)
        expect(client.searches.size).to eq(1)
      end
    end
  end
end

# Selecting values of two or more option types means one variant carrying a
# value of each ("blue AND XL" is a product that sells a blue XL), as core's
# `Product.with_option_value_ids` decides on Spree 6. The index holds each
# product's values as one set, so it can only pre-filter: the authorized scope
# is narrowed through core's scope before intersecting, as Spree's Meilisearch
# provider does when its index cannot answer exactly.
RSpec.describe Spree::SearchProvider::Typesense, 'search requests across option types' do
  let(:store)    { instance_double('Spree::Store', id: 7, code: 'shop') }
  let(:provider) { described_class.new(store) }
  let(:scope)    { FakeScope.new(%w[prod_1 prod_2 prod_3]) }
  let(:client) do
    RecordingTypesenseClient.new do |_kind, _params|
      { 'found' => 3, 'hits' => %w[prod_1 prod_2 prod_3].map { |pid| { 'document' => { 'product_id' => pid } } } }
    end
  end

  before do
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
    allow(provider).to receive(:client).and_return(client)
  end

  def search(grouped)
    allow(provider).to receive(:group_option_values_by_type).and_return(grouped)
    provider.search_and_filter(scope: scope, filters: { 'with_option_value_ids' => grouped.values.flatten })
  end

  it 'narrows the scope through core when values of two option types are selected' do
    allow(scope).to receive(:with_option_value_ids).and_return(FakeScope.new(%w[prod_2]))

    result = search(1 => %w[ov_blue], 2 => %w[ov_xl ov_l])

    expect(scope).to have_received(:with_option_value_ids).with(%w[ov_blue ov_xl ov_l])
    expect(result.products.map(&:prefixed_id)).to eq(%w[prod_2])
  end

  it 'still asks Typesense for the per-type pre-filter' do
    allow(scope).to receive(:with_option_value_ids).and_return(scope)

    search(1 => %w[ov_blue], 2 => %w[ov_xl])

    expect(client.searches.sole[:filter_by]).to include('option_value_ids:=ov_blue', 'option_value_ids:=ov_xl')
  end

  # One type is a union of values, which the index answers exactly.
  it 'leaves the scope alone when the values are all of one option type' do
    allow(scope).to receive(:with_option_value_ids)

    result = search(1 => %w[ov_blue ov_red])

    expect(scope).not_to have_received(:with_option_value_ids)
    expect(result.products.map(&:prefixed_id)).to eq(%w[prod_1 prod_2 prod_3])
  end

  it 'leaves the scope alone when no option value is selected' do
    allow(scope).to receive(:with_option_value_ids)

    search({})

    expect(scope).not_to have_received(:with_option_value_ids)
  end
end
