require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense, '#reindex' do
  let(:store)    { instance_double('Spree::Store', id: 1, code: 'shop') }
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

# A rejected document must neither stop the reindex nor be counted as indexed,
# and the reindex must end in an error, so `rake spree:search:reindex` fails
# visibly. Client double: no server needed.
RSpec.describe Spree::SearchProvider::Typesense, '#reindex with documents Typesense rejects' do
  let(:store)     { instance_double('Spree::Store', id: 1, code: 'shop') }
  let(:provider)  { described_class.new(store) }
  let(:relation)  { double('ActiveRecord::Relation') }
  let(:documents) { instance_double(Typesense::Documents) }
  let(:logged)    { [] }

  def product(id) = double("Spree::Product##{id}", id: id)
  def doc_for(product) = { 'id' => "prod_#{product.id}_en_USD", 'product_id' => "prod_#{product.id}" }

  before do
    products = [product(1), product(2), product(3)]
    presenter_class = class_double('SpreeTypesense::ProductPresenter')
    allow(presenter_class).to receive(:new) { |p, _| instance_double(SpreeTypesense::ProductPresenter, call: [doc_for(p)]) }
    allow(provider).to receive(:presenter_class).and_return(presenter_class)
    allow(provider).to receive(:ensure_index_settings!)
    allow(relation).to receive_messages(reorder: relation, preload_associations_lazily: relation)
    allow(relation).to receive(:find_in_batches).and_yield(products.first(2)).and_yield(products.last(1))

    collection = instance_double(Typesense::Collection, documents: documents)
    allow(provider).to receive(:client)
      .and_return(instance_double(Typesense::Client, collections: { 'products_shop' => collection }))
    allow(documents).to receive(:import).and_return(
      [{ 'success' => true }, { 'success' => false, 'error' => 'Bad price.' }],
      [{ 'success' => true }]
    )

    logger = Logger.new(File::NULL)
    %i[info warn error].each { |level| allow(logger).to receive(level) { |msg = nil, &blk| logged << (msg || blk&.call) } }
    allow(Rails).to receive(:logger).and_return(logger)
  end

  it 'imports every batch, then raises naming the rejected documents' do
    expect { provider.reindex(relation) }.to raise_error(described_class::ImportError, /prod_2_en_USD/) { |e|
      expect(e.failures.map { |f| f[:id] }).to eq(%w[prod_2_en_USD])
    }
    expect(documents).to have_received(:import).twice
  end

  it 'counts only the documents Typesense accepted' do
    provider.reindex(relation) rescue described_class::ImportError

    expect(logged.grep(/indexed 1 \(1 total\)/)).not_to be_empty
    expect(logged.grep(/reindex complete: 2 documents indexed, 1 failed/)).not_to be_empty
  end
end
