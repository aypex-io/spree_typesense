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
        'price' => 39.0, 'created_at' => 1_700_000_000 }
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
          'price' => 9.0, 'created_at' => 1_700_000_000 }
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
        'price' => 1.0, 'created_at' => 1_700_000_000 }
    ])
    provider.remove_by_id('prod_b')

    expect {
      provider.client.collections[provider.collection_name].documents['prod_b_en_USD'].retrieve
    }.to raise_error(Typesense::Error::ObjectNotFound)
  end
end
