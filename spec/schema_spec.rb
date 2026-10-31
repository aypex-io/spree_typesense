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

  # This is the spree_core 5.5.1 contract (the oldest supported release) plus
  # preorder (emitted by spree_core 5.6+ but not 5.5.1; declared as an
  # optional field), collection_ids (6.x only) and the derived
  # available_on_i. Must stay an EXACT set — match_array, not
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
    expect(definition[:fields].map { |f| f[:name] })
      .to match_array(expected + %w[preorder collection_ids available_on_i])
  end

  # Emitted on Spree 6.x only, for the in_collection filter. Filtering needs no
  # facet, and collection facets are not offered.
  it 'declares collection_ids as an optional, filterable string array' do
    expect(field('collection_ids')).to include(type: 'string[]', optional: true, facet: false)
    expect(described_class::FACET_FIELDS).not_to include('collection_ids')
  end

  it 'declares no field the presenter does not emit' do
    names = definition[:fields].map { |f| f[:name] }
    expect(names).not_to include('brand', 'best_selling_score', 'taxon_ids')
  end

  # spree_core 5.5.1 (the oldest supported release) does not emit `preorder`
  # — that only appears in 5.6+. Optional, so one collection takes documents
  # from either, and searches can filter on it (`preorder:=true`) whether or
  # not a document carries it.
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

  # A collection created by an earlier release has to gain the fields added
  # since, in place: Typesense PATCHes new fields onto a live collection, but
  # cannot change a field's type there. These read a live schema as Typesense
  # returns it (string keys, extra attributes) and need no server.
  describe 'comparing against a live collection' do
    def live(fields) = fields.map { |f| { 'facet' => false, 'index' => true, 'optional' => true }.merge(f) }

    let(:all_live_fields) do
      live(definition[:fields].map { |f| { 'name' => f[:name], 'type' => f[:type] } })
    end

    describe '.missing_fields' do
      it 'names nothing when the live collection already has every field' do
        expect(described_class.missing_fields(all_live_fields)).to eq([])
      end

      # The collection a 0.1.x release created: no collection_ids.
      it 'returns the declared definition of each field the live collection lacks' do
        legacy = all_live_fields.reject { |f| f['name'] == 'collection_ids' }

        expect(described_class.missing_fields(legacy)).to eq([field('collection_ids')])
      end

      it 'ignores fields the live collection has that the definition does not' do
        extra = all_live_fields + live([{ 'name' => 'legacy_only', 'type' => 'string' }])

        expect(described_class.missing_fields(extra)).to eq([])
      end
    end

    describe '.type_mismatches' do
      it 'names nothing when every shared field has the declared type' do
        expect(described_class.type_mismatches(all_live_fields)).to eq([])
      end

      it 'names each shared field whose live type differs, with both types' do
        drifted = all_live_fields.map { |f| f['name'] == 'units_sold_count' ? f.merge('type' => 'int64') : f }

        expect(described_class.type_mismatches(drifted))
          .to eq([{ name: 'units_sold_count', live_type: 'int64', type: 'int32' }])
      end

      it 'does not report a field the live collection lacks: that one is added, not changed' do
        legacy = all_live_fields.reject { |f| f['name'] == 'collection_ids' }

        expect(described_class.type_mismatches(legacy)).to eq([])
      end
    end

    # Typesense checks every stored document against a field added in place,
    # and documents indexed before the field existed do not carry it. So a
    # field added after the first release must be optional, or the PATCH that
    # adds it fails on every existing collection.
    it 'declares every field added since 0.1.x as optional' do
      %w[collection_ids].each do |name|
        expect(field(name)[:optional]).to be(true), "#{name} must be optional to be added in place"
      end
    end
  end

  it 'creates the collection against a real server' do
    typesense_client.collections['products_test'].delete rescue nil
    expect(typesense_client.collections.create(definition)['name']).to eq('products_test')
  end
end
