require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense::Schema do
  subject(:definition) { described_class.definition('products_test') }

  def field(name) = definition[:fields].find { |f| f[:name] == name }

  it 'names the collection' do
    expect(definition[:name]).to eq('products_test')
  end

  it 'uses a NUMERIC default sorting field (Typesense rejects string defaults)' do
    expect(definition[:default_sorting_field]).to eq('units_sold_count')
    expect(field('units_sold_count')[:type]).to eq('int32')
  end

  # REGRESSION: the first draft typed created_at as int64. The presenter emits
  # an ISO8601 string, so Typesense would reject every real document.
  it 'types the timestamp fields as sortable strings, not integers' do
    %w[created_at updated_at available_on].each do |f|
      expect(field(f)[:type]).to eq('string'), "#{f} must be string"
      expect(field(f)[:sort]).to be(true), "#{f} must be sortable"
    end
  end

  # REGRESSION: the first draft called this taxon_ids, which the presenter
  # never emits — category filtering would have silently matched nothing.
  it 'declares category_ids (never taxon_ids)' do
    expect(field('category_ids')).not_to be_nil
    expect(definition[:fields].map { |f| f[:name] }).not_to include('taxon_ids')
  end

  # This is the spree_core 5.5.1 contract (what TKF runs) plus preorder
  # (emitted by spree_core 5.6+ but not 5.5.1; declared as an optional field
  # for forward-compatibility). Must stay an EXACT set — match_array, not
  # include — so an invented field re-added to the schema is caught here,
  # same as it caught brand/best_selling_score/taxon_ids the first time.
  it 'declares every field the presenter emits' do
    expected = %w[
      product_id locale currency name description slug price compare_at_price
      status sku in_stock store_ids channel_ids discontinue_on
      category_ids category_names option_type_ids option_type_names
      option_value_ids option_values tags units_sold_count
      available_on created_at updated_at
    ]
    expect(definition[:fields].map { |f| f[:name] }).to match_array(expected + %w[preorder available_on_i])
  end

  it 'declares no field the presenter does not emit' do
    names = definition[:fields].map { |f| f[:name] }
    expect(names).not_to include('brand', 'best_selling_score', 'taxon_ids')
  end

  # spree_core 5.5.1 (what TKF runs, and what we develop against) does not
  # emit `preorder` — that only appears in 5.6+. Declared separately from the
  # "declares every field the presenter emits" contract above (which is
  # pinned to 5.5.1) so the collection stays valid if a 5.6 document with
  # `preorder` ever arrives, without requiring or expecting the field.
  it 'declares preorder as an optional, facetable bool for 5.6 forward-compat' do
    expect(field('preorder')[:type]).to eq('bool')
    expect(field('preorder')[:optional]).to be(true)
    expect(field('preorder')[:facet]).to be(true)
  end

  it 'makes every FACET_FIELD actually facetable' do
    described_class::FACET_FIELDS.each do |f|
      expect(field(f)[:facet]).to be(true), "#{f} listed in FACET_FIELDS but not facet:true"
    end
  end

  it 'creates the collection against a real server' do
    typesense_client.collections['products_test'].delete rescue nil
    expect(typesense_client.collections.create(definition)['name']).to eq('products_test')
  end
end
