require 'spec_helper'

# Disjunctive faceting: when a user has selected option values, the counts for
# THAT option type must be computed with that type's own filter removed.
# Otherwise selecting "Red" reports every other colour as zero and the UI can
# never offer a second choice.
RSpec.describe Spree::SearchProvider::Typesense, 'disjunctive faceting' do
  let(:store)    { instance_double('Spree::Store', id: 7, code: 'tkfdisj') }
  let(:provider) { described_class.new(store) }

  # One option type (Colour), three products: two Red, one Blue.
  let(:colour) { FakeOptionType.new(prefixed_id: 'optt_colour', name: 'Colour', label: 'Colour', kind: 'color') }
  let(:red) do
    FakeOptionValue.new(id: 'red', prefixed_id: 'ov_red', name: 'red', label: 'Red', position: 1,
                        color_code: '#f00', option_type_id: 1, option_type: colour,
                        image: FakeImage.new(attached: false))
  end
  let(:blue) do
    FakeOptionValue.new(id: 'blue', prefixed_id: 'ov_blue', name: 'blue', label: 'Blue', position: 2,
                        color_code: '#00f', option_type_id: 1, option_type: colour,
                        image: FakeImage.new(attached: false))
  end

  def doc(pid, option_value_ids)
    { 'id' => "#{pid}_en_USD", 'product_id' => pid, 'locale' => 'en', 'currency' => 'USD',
      'name' => "Product #{pid}", 'status' => 'active', 'in_stock' => true,
      'store_ids' => ['7'], 'discontinue_on' => 0, 'units_sold_count' => 0,
      'price' => 10.0, 'option_value_ids' => option_value_ids,
      'available_on' => '2020-01-01T00:00:00Z', 'created_at' => '2020-01-01T00:00:00Z' }
  end

  before do
    provider.client.collections[provider.collection_name].delete rescue nil
    provider.ensure_index_settings!
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
    provider.index_batch([
      doc('prod_1', ['ov_red']),
      doc('prod_2', ['ov_red']),
      doc('prod_3', ['ov_blue'])
    ])
    stub_ar_lookup(Spree::OptionValue, [red, blue])
    stub_ar_lookup(Spree::Taxon, [])
  end

  def option_facet(result)
    result.filters.find { |f| f[:id] == 'optt_colour' }
  end

  def counts(result)
    option_facet(result)[:options].to_h { |o| [o[:id], o[:count]] }
  end

  context 'with ov_red selected' do
    subject(:result) do
      allow(provider).to receive(:group_option_values_by_type).and_return(1 => ['ov_red'])
      provider.filters(scope: FakeScope.new(%w[prod_1 prod_2 prod_3]),
                       filters: { 'with_option_value_ids' => ['ov_red'] })
    end

    # THE TEST THAT MATTERS. A single-query implementation reports ov_blue as
    # absent/0 because the main query is filtered to ov_red.
    it 'still reports the true count for the unselected value of the same type' do
      expect(counts(result)['ov_blue']).to eq(1)
    end

    it 'keeps the selected value at its own filtered count' do
      expect(counts(result)['ov_red']).to eq(2)
    end

    # The main query IS still filtered — only the facet counts are widened.
    it 'leaves the result set itself filtered to the selection' do
      expect(result.total_count).to eq(2)
    end
  end

  context 'across two option types' do
    let(:size) { FakeOptionType.new(prefixed_id: 'optt_size', name: 'Size', label: 'Size', kind: 'text') }
    let(:small) do
      FakeOptionValue.new(id: 'small', prefixed_id: 'ov_small', name: 'small', label: 'Small', position: 1,
                          color_code: nil, option_type_id: 2, option_type: size,
                          image: FakeImage.new(attached: false))
    end
    let(:large) do
      FakeOptionValue.new(id: 'large', prefixed_id: 'ov_large', name: 'large', label: 'Large', position: 2,
                          color_code: nil, option_type_id: 2, option_type: size,
                          image: FakeImage.new(attached: false))
    end

    before do
      provider.client.collections[provider.collection_name].delete rescue nil
      provider.ensure_index_settings!
      provider.index_batch([
        doc('prod_1', %w[ov_red ov_small]),
        doc('prod_2', %w[ov_red ov_large]),
        doc('prod_3', %w[ov_blue ov_small])
      ])
      stub_ar_lookup(Spree::OptionValue, [red, blue, small, large])
    end

    subject(:result) do
      allow(provider).to receive(:group_option_values_by_type).and_return(1 => ['ov_red'], 2 => ['ov_small'])
      provider.filters(scope: FakeScope.new(%w[prod_1 prod_2 prod_3]),
                       filters: { 'with_option_value_ids' => %w[ov_red ov_small] })
    end

    # Colour counts drop the colour filter but KEEP the size filter:
    # size=small leaves prod_1 (red) and prod_3 (blue) -> red 1, blue 1.
    it 'relaxes only the facet\'s own type, keeping other types applied' do
      colour_counts = result.filters.find { |f| f[:id] == 'optt_colour' }[:options].to_h { |o| [o[:id], o[:count]] }
      expect(colour_counts).to eq('ov_red' => 1, 'ov_blue' => 1)
    end

    # Size counts drop the size filter but KEEP colour=red:
    # colour=red leaves prod_1 (small) and prod_2 (large) -> small 1, large 1.
    it 'does the same for the second type' do
      size_counts = result.filters.find { |f| f[:id] == 'optt_size' }[:options].to_h { |o| [o[:id], o[:count]] }
      expect(size_counts).to eq('ov_small' => 1, 'ov_large' => 1)
    end
  end

  # THE SHARPEST ENGINE DIVERGENCE IN THIS GEM. A single search raises
  # Typesense::Error::* on a bad filter or a missing collection; multi_search
  # answers HTTP 200 and puts {error, code} in the individual sub-result. A
  # rescue-only error path would therefore treat a failed search as "no facets"
  # and serve wrong counts with no signal. These specs pin that.
  context 'when a multi_search sub-result carries an error body' do
    let(:ok_sub_result) do
      { 'found' => 2, 'hits' => [],
        'facet_counts' => [{ 'field_name' => 'option_value_ids',
                             'counts' => [{ 'value' => 'ov_red', 'count' => 2 }] }] }
    end

    def stub_multi_search(results)
      multi = instance_double('Typesense::MultiSearch')
      allow(multi).to receive(:perform).and_return('results' => results)
      allow(provider.client).to receive(:multi_search).and_return(multi)
      allow(provider).to receive(:group_option_values_by_type).and_return(1 => ['ov_red'])
    end

    subject(:result) { provider.filters(scope: FakeScope.new(%w[prod_1])) }

    # POSITIVE CONTROL: proves the stub really does drive the multi_search path,
    # so the failure specs below cannot pass just because nothing ran.
    it 'builds facets normally when every sub-result succeeds' do
      stub_multi_search([ok_sub_result, ok_sub_result])
      expect(result.filters.find { |f| f[:id] == 'optt_colour' }[:options].first[:count]).to eq(2)
    end

    it 'degrades to the empty-but-valid result when a LATER sub-result errors' do
      stub_multi_search([ok_sub_result, { 'error' => 'Bad filter', 'code' => 400 }])
      expect(result.filters).to eq([])
      expect(result.total_count).to eq(0)
      expect(result.default_sort).to eq('manual')
      expect(result.sort_options).not_to be_empty
    end

    it 'degrades the same way when the MAIN sub-result errors' do
      stub_multi_search([{ 'error' => 'Collection not found', 'code' => 404 }, ok_sub_result])
      expect(result.filters).to eq([])
      expect(result.total_count).to eq(0)
    end

    it 'does not raise' do
      stub_multi_search([ok_sub_result, { 'error' => 'Bad filter', 'code' => 400 }])
      expect { result }.not_to raise_error
    end

    # The whole point: a partial failure must NOT quietly fall through to the
    # main query's counts, which are exactly the wrong ones (every unselected
    # value reads zero) — that is the bug disjunctive faceting exists to fix.
    it 'does not silently serve the un-relaxed main-query counts' do
      stub_multi_search([ok_sub_result, { 'error' => 'Bad filter', 'code' => 400 }])
      expect(result.filters.find { |f| f[:id] == 'optt_colour' }).to be_nil
    end
  end

  context 'with nothing selected' do
    it 'issues a single search rather than paying for a multi_search' do
      allow(provider).to receive(:group_option_values_by_type).and_return({})
      expect(provider).not_to receive(:execute_multi_search)
      result = provider.filters(scope: FakeScope.new(%w[prod_1 prod_2 prod_3]))
      expect(counts(result)).to eq('ov_red' => 2, 'ov_blue' => 1)
    end
  end
end
