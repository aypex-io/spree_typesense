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
      %w[price -price name -name -available_on available_on best_selling].map { |id| { id: id, label: nil } }
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


# REGRESSION: the rescue clauses named `Typesense::Error::Error`, which does not
# exist — the gem's base class is `Typesense::Error`. Ruby resolves a rescue's
# constant only when an exception is actually raised, so the mistake was
# invisible until a real API error occurred, at which point the rescue ITSELF
# raised NameError and the failure escaped as a storefront 500 instead of
# degrading. These specs drive a genuine engine error (a collection that was
# never created — precisely the "run reindex first" case the warning names)
# rather than stubbing, because stubbing the method under test is what let this
# hide in the first place.
RSpec.describe Spree::SearchProvider::Typesense, 'when the engine really errors' do
  let(:store)    { instance_double('Spree::Store', id: 7, code: 'nosuchcollection') }
  let(:provider) { described_class.new(store) }

  before do
    provider.client.collections[provider.collection_name].delete rescue nil
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
  end

  it 'degrades search_and_filter to an empty result rather than raising' do
    result = nil
    expect { result = provider.search_and_filter(scope: FakeScope.new([])) }.not_to raise_error
    expect(result.total_count).to eq(0)
    expect(result.products).to be_empty
  end

  it 'degrades filters to an empty-but-valid result rather than raising' do
    result = nil
    expect { result = provider.filters(scope: FakeScope.new([])) }.not_to raise_error
    expect(result.filters).to eq([])
    expect(result.total_count).to eq(0)
    expect(result.default_sort).to eq('manual')
  end
end

# Typesense caps the number of facet VALUES it returns (default 10, we raise it
# to 100) and truncates SILENTLY, keeping the highest values. Deriving the price
# range from those keys therefore reports a min that is simply wrong once a store
# has more distinct prices than the cap. Typesense computes `stats.min`/`stats.max`
# over the full matching set, so the range must come from stats instead.
RSpec.describe Spree::SearchProvider::Typesense, '#filters price range beyond the facet cap' do
  let(:store)    { instance_double('Spree::Store', id: 7, code: 'tkfcap') }
  let(:provider) { described_class.new(store) }

  # 120 distinct prices, 3.5 .. 122.5 — more than the 100-value cap.
  let(:prices)    { (0...120).map { |i| i + 3.5 } }
  let(:lowest)    { 3.5 }
  let(:highest)   { 122.5 }

  before do
    provider.client.collections[provider.collection_name].delete rescue nil
    provider.ensure_index_settings!
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
    provider.index_batch(prices.each_with_index.map do |price, i|
      { 'id' => "prod_#{i}_en_USD", 'product_id' => "prod_#{i}", 'locale' => 'en', 'currency' => 'USD',
        'name' => "Product #{i}", 'status' => 'active', 'in_stock' => true, 'store_ids' => ['7'],
        'discontinue_on' => 0, 'units_sold_count' => 0, 'price' => price,
        'available_on' => '2020-01-01T00:00:00Z', 'created_at' => '2020-01-01T00:00:00Z' }
    end)
  end

  subject(:price_facet) do
    provider.filters(scope: FakeScope.new([])).filters.find { |f| f[:id] == 'price' }
  end

  # The truncation keeps the HIGH values, so max survives a key-derived
  # implementation and only min exposes the bug — assert both anyway.
  it 'reports the true lowest price, not the lowest surviving facet key' do
    expect(price_facet[:min]).to eq(lowest)
  end

  it 'reports the true highest price' do
    expect(price_facet[:max]).to eq(highest)
  end

  # stats are computed over the FILTERED set, so a narrowed search must narrow
  # the reported range too — a hardcoded global min/max would pass the above.
  it 'reports the range of the filtered set, not of the whole collection' do
    facet = provider.filters(scope: FakeScope.new([]), filters: { 'price_gte' => 50.0 })
                    .filters.find { |f| f[:id] == 'price' }
    expect(facet[:min]).to eq(50.5)
    expect(facet[:max]).to eq(highest)
  end
end

RSpec.describe Spree::SearchProvider::Typesense::Facets, '.price_facet' do
  # Guards the precedence directly: if an implementation ever falls back to keys
  # while stats are available, these disagree and the spec catches it.
  it 'prefers stats over the (truncatable) facet keys' do
    facet = described_class.price_facet({ '80.0' => 1, '90.0' => 1 }, { 'min' => 5.0, 'max' => 90.0 }, 'USD')
    expect(facet).to eq(id: 'price', type: 'price_range', min: 5.0, max: 90.0, currency: 'USD')
  end

  # Only numeric fields get min/max; a caller that has none still needs a
  # renderable facet rather than nil bounds.
  it 'falls back to the facet keys when no stats are present' do
    facet = described_class.price_facet({ '80.0' => 1, '90.0' => 1 }, nil, 'USD')
    expect(facet).to include(min: 80.0, max: 90.0)
  end

  # REGRESSION: guarding on the stats hash being truthy rather than on the key
  # being present emitted min: nil, max: nil and broke the storefront's price
  # slider. Typesense really does return this shape — a stats block with only
  # total_values — for non-numeric facets, and for `price` itself whenever the
  # search matches nothing.
  it 'falls back to the facet keys when stats exist but carry no min/max' do
    facet = described_class.price_facet({ '80.0' => 1, '90.0' => 1 }, { 'total_values' => 0 }, 'USD')
    expect(facet).to include(min: 80.0, max: 90.0)
  end

  it 'never emits nil bounds' do
    [nil, {}, { 'total_values' => 0 }].each do |stats|
      facet = described_class.price_facet({ '80.0' => 1 }, stats, 'USD')
      expect([facet[:min], facet[:max]]).to all(be_a(Numeric)), "nil bound for stats=#{stats.inspect}"
    end
  end
end

RSpec.describe Spree::SearchProvider::Typesense::Facets, '.normalize_stats' do
  it 'extracts per-field stats and ignores fields that have none' do
    raw = [{ 'field_name' => 'price', 'counts' => [], 'stats' => { 'min' => 1.0, 'max' => 9.0 } },
           { 'field_name' => 'tags',  'counts' => [] }]
    expect(described_class.normalize_stats(raw)).to eq('price' => { 'min' => 1.0, 'max' => 9.0 })
  end

  # Non-numeric facets DO carry a stats block — it just has no min/max. Keep it
  # rather than filtering: the consumer guards on the key, and dropping blocks
  # here would hide what the engine actually returned.
  it 'keeps the total_values-only block non-numeric facets return' do
    raw = [{ 'field_name' => 'preorder', 'counts' => [], 'stats' => { 'total_values' => 0 } }]
    expect(described_class.normalize_stats(raw)).to eq('preorder' => { 'total_values' => 0 })
  end
end

RSpec.describe Spree::SearchProvider::Typesense::Facets, '.option_facets' do
  let(:colour) { FakeOptionType.new(prefixed_id: 'optt_colour', name: 'Colour', label: 'Colour', kind: 'color') }
  let(:size)   { FakeOptionType.new(prefixed_id: 'optt_size', name: 'Size', label: 'Size', kind: 'text') }

  def ov(id, type, position, type_id, image: FakeImage.new(attached: false))
    FakeOptionValue.new(id: id, prefixed_id: "ov_#{id}", name: id, label: id.capitalize, position: position,
                        color_code: "##{id[0, 3]}", option_type_id: type_id, option_type: type, image: image)
  end

  # Deliberately declared out of position order so an implementation that just
  # preserves the distribution's key order cannot pass.
  let(:records) { [ov('red', colour, 2, 1), ov('blue', colour, 1, 1), ov('small', size, 1, 2)] }
  let(:distribution) { { 'ov_red' => 5, 'ov_blue' => 3, 'ov_small' => 9 } }

  before { stub_ar_lookup(Spree::OptionValue, records) }

  subject(:facets) { described_class.option_facets(distribution) }

  it 'returns one entry per option TYPE, not per value' do
    expect(facets.map { |f| f[:id] }).to contain_exactly('optt_colour', 'optt_size')
  end

  it 'carries the option type metadata' do
    expect(facets.find { |f| f[:id] == 'optt_colour' }).to include(
      type: 'option', name: 'Colour', label: 'Colour', kind: 'color'
    )
  end

  it 'sorts options by position, not by distribution order' do
    colour_facet = facets.find { |f| f[:id] == 'optt_colour' }
    expect(colour_facet[:options].map { |o| o[:id] }).to eq(%w[ov_blue ov_red])
  end

  it 'emits exactly the documented option key set' do
    option = facets.find { |f| f[:id] == 'optt_size' }[:options].first
    expect(option.keys).to contain_exactly(:id, :name, :label, :position, :color_code, :image_url, :count)
    expect(option).to include(id: 'ov_small', name: 'small', label: 'Small', position: 1, count: 9)
  end

  it 'leaves image_url nil when no image is attached' do
    expect(facets.flat_map { |f| f[:options] }.map { |o| o[:image_url] }).to all(be_nil)
  end

  it 'resolves image_url through cdn_image_url when an image is attached' do
    imaged = ov('red', colour, 2, 1, image: FakeImage.new(attached: true))
    stub_ar_lookup(Spree::OptionValue, [imaged])
    url_helpers = double('url_helpers')
    allow(url_helpers).to receive(:cdn_image_url).with(imaged.image).and_return('https://cdn/red.png')
    allow(Rails).to receive(:application).and_return(double('app', routes: double('routes', url_helpers: url_helpers)))

    facet = described_class.option_facets('ov_red' => 1)
    expect(facet.first[:options].first[:image_url]).to eq('https://cdn/red.png')
  end

  # A stale index can carry values that no longer exist in the database.
  it 'drops distribution entries with no matching OptionValue record' do
    facets = described_class.option_facets(distribution.merge('ov_deleted' => 4))
    expect(facets.flat_map { |f| f[:options] }.map { |o| o[:id] }).not_to include('ov_deleted')
  end
end

RSpec.describe Spree::SearchProvider::Typesense::Facets, '.category_facet' do
  let(:records) do
    [FakeCatalog::Category.new(id: 'a', prefixed_id: 'tax_a', names: 'Shirts', permalink: 'cat/shirts'),
     FakeCatalog::Category.new(id: 'b', prefixed_id: 'tax_b', names: 'Shoes', permalink: 'cat/shoes')]
  end

  before { stub_ar_lookup(category_class, records) }

  subject(:facet) { described_class.category_facet('tax_a' => 4, 'tax_b' => 2) }

  it "uses the literal id 'categories'" do
    expect(facet).to include(id: 'categories', type: 'category')
  end

  it 'emits exactly the documented category key set' do
    expect(facet[:options].first.keys).to contain_exactly(:id, :name, :permalink, :count)
    expect(facet[:options]).to contain_exactly(
      { id: 'tax_a', name: 'Shirts', permalink: 'cat/shirts', count: 4 },
      { id: 'tax_b', name: 'Shoes',  permalink: 'cat/shoes',  count: 2 }
    )
  end

  it 'drops distribution entries with no matching Taxon record' do
    f = described_class.category_facet('tax_a' => 4, 'tax_gone' => 1)
    expect(f[:options].map { |o| o[:id] }).to eq(['tax_a'])
  end
end

RSpec.describe Spree::SearchProvider::Typesense::Facets, '.build' do
  before do
    stub_ar_lookup(Spree::OptionValue, [
                     FakeOptionValue.new(id: 'red', prefixed_id: 'ov_red', name: 'red', label: 'Red', position: 1,
                                         color_code: '#f00', option_type_id: 1,
                                         option_type: FakeOptionType.new(prefixed_id: 'optt_colour', name: 'Colour',
                                                                         label: 'Colour', kind: 'color'),
                                         image: FakeImage.new(attached: false))
                   ])
    stub_ar_lookup(category_class,
                   [FakeCatalog::Category.new(id: 'a', prefixed_id: 'tax_a', names: 'Shirts', permalink: 'shirts')])
  end

  it 'appends option and category facets after the 6a price/availability facets' do
    distribution = {
      'price' => { '10.0' => 1 }, 'in_stock' => { 'true' => 1 },
      'option_value_ids' => { 'ov_red' => 1 }, 'category_ids' => { 'tax_a' => 1 }
    }
    expect(described_class.build(distribution, currency: 'USD').map { |f| f[:id] })
      .to eq(%w[price availability optt_colour categories])
  end

  it 'omits option and category facets when the distribution has none' do
    expect(described_class.build({ 'in_stock' => { 'true' => 1 } }, currency: 'USD').map { |f| f[:id] })
      .to eq(['availability'])
  end
end

RSpec.describe Spree::SearchProvider::Typesense::Facets, '.normalize' do
  it 'turns Typesense facet_counts into a field => {value => count} hash' do
    raw = [{ 'field_name' => 'in_stock',
             'counts' => [{ 'value' => 'true', 'count' => 3 }, { 'value' => 'false', 'count' => 1 }] }]
    expect(described_class.normalize(raw)).to eq('in_stock' => { 'true' => 3, 'false' => 1 })
  end
end
