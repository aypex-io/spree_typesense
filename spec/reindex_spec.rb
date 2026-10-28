require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense, '#reindex' do
  let(:store)    { instance_double('Spree::Store', id: 1, code: 'tkf') }
  let(:provider) { described_class.new(store) }
  let(:relation) { double('ActiveRecord::Relation') }

  def product(id) = double("Spree::Product##{id}", id: id)

  def doc_for(id)
    { 'id' => "prod_#{id}_en_USD", 'product_id' => "prod_#{id}", 'locale' => 'en',
      'currency' => 'USD', 'status' => 'active', 'name' => "Product #{id}",
      'price' => 9.0, 'in_stock' => true, 'store_ids' => ['1'],
      'discontinue_on' => 0, 'units_sold_count' => 0,
      'created_at' => '2024-01-01T00:00:00Z' }
  end

  def stub_presenter_for(products)
    presenter_class = class_double('SpreeTypesense::ProductPresenter')
    allow(provider).to receive(:presenter_class).and_return(presenter_class)
    products.each do |p|
      allow(presenter_class).to receive(:new).with(p, store)
                                              .and_return(instance_double(SpreeTypesense::ProductPresenter,
                                                                           call: [doc_for(p.id)]))
    end
  end

  before do
    provider.client.collections[provider.collection_name].delete rescue nil
    allow(relation).to receive(:reorder).with(id: :asc).and_return(relation)
    allow(relation).to receive(:preload_associations_lazily).and_return(relation)
  end

  it 'defaults the scope to store.products, batches at 500, and returns the indexed document count' do
    products = [product(1), product(2)]
    stub_presenter_for(products)
    allow(store).to receive(:products).and_return(relation)
    expect(relation).to receive(:find_in_batches).with(batch_size: 500).and_yield(products)

    count = provider.reindex

    expect(count).to eq(2)
    doc = provider.client.collections[provider.collection_name].documents['prod_1_en_USD'].retrieve
    expect(doc['product_id']).to eq('prod_1')
  end

  it 'uses the given scope instead of store.products when one is passed' do
    products = [product(3)]
    stub_presenter_for(products)
    expect(store).not_to receive(:products)
    allow(relation).to receive(:find_in_batches).with(batch_size: 500).and_yield(products)

    count = provider.reindex(relation)

    expect(count).to eq(1)
  end

  it 'ensures index settings before indexing any batch' do
    products = [product(4)]
    stub_presenter_for(products)
    allow(store).to receive(:products).and_return(relation)
    allow(relation).to receive(:find_in_batches).with(batch_size: 500).and_yield(products)

    expect(provider).to receive(:ensure_index_settings!).ordered.and_call_original
    expect(provider).to receive(:index_batch).ordered.and_call_original

    provider.reindex
  end

  it 'skips a batch that produces no documents' do
    products = [product(5)]
    presenter_class = class_double('SpreeTypesense::ProductPresenter')
    allow(provider).to receive(:presenter_class).and_return(presenter_class)
    allow(presenter_class).to receive(:new).with(products.first, store)
                                            .and_return(instance_double(SpreeTypesense::ProductPresenter, call: []))
    allow(store).to receive(:products).and_return(relation)
    allow(relation).to receive(:find_in_batches).with(batch_size: 500).and_yield(products)

    expect(provider).not_to receive(:index_batch)

    expect(provider.reindex).to eq(0)
  end
end
