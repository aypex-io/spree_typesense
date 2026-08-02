require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense do
  let(:store)    { instance_double('Spree::Store', id: 1, code: 'tkf') }
  let(:provider) { described_class.new(store) }

  before do
    provider.client.collections[provider.collection_name].delete rescue nil
    provider.ensure_index_settings!
  end

  it 'requires background indexing' do
    expect(described_class.indexing_required?).to be(true)
  end

  it 'indexes a batch and makes documents retrievable' do
    provider.index_batch([
      { 'id' => 'prod_a_en_USD', 'product_id' => 'prod_a', 'locale' => 'en',
        'currency' => 'USD', 'status' => 'active', 'name' => 'Tongkat Ali',
        'price' => 39.0, 'in_stock' => true, 'store_ids' => ['1'],
        'discontinue_on' => 0, 'units_sold_count' => 0,
        'created_at' => '2024-01-01T00:00:00Z' }
    ])

    doc = provider.client.collections[provider.collection_name].documents['prod_a_en_USD'].retrieve
    expect(doc['product_id']).to eq('prod_a')
  end

  it 'indexes a product by delegating to the configured presenter' do
    product = instance_double('Spree::Product')
    presenter = instance_double(
      Spree::SearchProvider::ProductPresenter,
      call: [
        { 'id' => 'prod_c_en_USD', 'product_id' => 'prod_c', 'locale' => 'en',
          'currency' => 'USD', 'status' => 'active', 'name' => 'Delegated',
          'price' => 9.0, 'in_stock' => true, 'store_ids' => ['1'],
          'discontinue_on' => 0, 'units_sold_count' => 0,
          'created_at' => '2024-01-01T00:00:00Z' }
      ]
    )
    presenter_class = class_double('Spree::SearchProvider::ProductPresenter', new: presenter)
    allow(provider).to receive(:presenter_class).and_return(presenter_class)

    provider.index(product)

    doc = provider.client.collections[provider.collection_name].documents['prod_c_en_USD'].retrieve
    expect(doc['product_id']).to eq('prod_c')
  end

  it 'removes a document by prefixed id' do
    provider.index_batch([
      { 'id' => 'prod_b_en_USD', 'product_id' => 'prod_b', 'locale' => 'en',
        'currency' => 'USD', 'status' => 'active', 'name' => 'Gone',
        'price' => 1.0, 'in_stock' => true, 'store_ids' => ['1'],
        'discontinue_on' => 0, 'units_sold_count' => 0,
        'created_at' => '2024-01-01T00:00:00Z' }
    ])
    provider.remove_by_id('prod_b')

    expect {
      provider.client.collections[provider.collection_name].documents['prod_b_en_USD'].retrieve
    }.to raise_error(Typesense::Error::ObjectNotFound)
  end

  it 'sanitizes prefixed_id so it cannot inject extra filter clauses' do
    provider.index_batch([
      { 'id' => 'prod_d_en_USD', 'product_id' => 'prod_d', 'locale' => 'en',
        'currency' => 'USD', 'status' => 'active', 'name' => 'Target',
        'price' => 1.0, 'in_stock' => true, 'store_ids' => ['1'],
        'discontinue_on' => 0, 'units_sold_count' => 0,
        'created_at' => '2024-01-01T00:00:00Z' },
      { 'id' => 'prod_e_en_USD', 'product_id' => 'prod_e', 'locale' => 'en',
        'currency' => 'USD', 'status' => 'active', 'name' => 'Bystander',
        'price' => 1.0, 'in_stock' => true, 'store_ids' => ['1'],
        'discontinue_on' => 0, 'units_sold_count' => 0,
        'created_at' => '2024-01-01T00:00:00Z' }
    ])

    # A naive `"product_id:=#{prefixed_id}"` interpolation turns this into
    # `product_id:=prod_d || product_id:=prod_e`, deleting the bystander too.
    provider.remove_by_id('prod_d || product_id:=prod_e')

    doc = provider.client.collections[provider.collection_name].documents['prod_e_en_USD'].retrieve
    expect(doc['product_id']).to eq('prod_e')
  end

  describe '#derive_fields (private)' do
    # Typesense silently returns zero results for range filters on string
    # fields, so system_conditions filters on this derived int64 instead of
    # the presenter's ISO8601 `available_on` string.
    it 'derives available_on_i as 0 when available_on is missing' do
      doc = provider.send(:derive_fields, { 'product_id' => 'prod_x' })
      expect(doc['available_on_i']).to eq(0)
    end

    it 'derives available_on_i as 0 when available_on is nil' do
      doc = provider.send(:derive_fields, { 'product_id' => 'prod_x', 'available_on' => nil })
      expect(doc['available_on_i']).to eq(0)
    end

    it 'derives available_on_i as the epoch of available_on when present' do
      doc = provider.send(:derive_fields, { 'product_id' => 'prod_x', 'available_on' => '2020-01-01T00:00:00Z' })
      expect(doc['available_on_i']).to eq(Time.parse('2020-01-01T00:00:00Z').to_i)
    end

    # The presenter (spree_core) emits symbol-keyed documents; this gem's own
    # specs use string keys. derive_fields must handle both.
    it 'handles symbol-keyed documents as emitted by the real presenter' do
      doc = provider.send(:derive_fields, { product_id: 'prod_x', available_on: '2020-01-01T00:00:00Z' })
      expect(doc['available_on_i']).to eq(Time.parse('2020-01-01T00:00:00Z').to_i)
    end
  end
end
