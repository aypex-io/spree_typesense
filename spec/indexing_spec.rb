require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense do
  let(:store)    { instance_double('Spree::Store', id: 1, code: 'shop') }
  let(:provider) { described_class.new(store) }

  before do
    provider.client.collections[provider.collection_name].delete rescue nil
    provider.ensure_index_settings!
  end

  it 'requires background indexing' do
    expect(described_class.indexing_required?).to be(true)
  end

  # Typesense alters a live collection in place, so a collection an earlier
  # release created gains the fields added since, and the plain
  # `rake spree:search:reindex` an upgrade runs is enough. Driven against the
  # real server, starting from the schema a 0.1.x release created.
  describe '#ensure_index_settings! against an already-existing collection' do
    let(:collection) { provider.client.collections[provider.collection_name] }
    let(:schema) { Spree::SearchProvider::Typesense::Schema }

    def doc(product_id, **extra)
      { 'id' => "#{product_id}_en_USD", 'product_id' => product_id, 'locale' => 'en', 'currency' => 'USD',
        'status' => 'active', 'name' => "Product #{product_id}", 'price' => 5.0, 'in_stock' => true,
        'store_ids' => ['1'], 'discontinue_on' => 0, 'units_sold_count' => 0,
        'created_at' => '2024-01-01T00:00:00Z' }.merge(extra)
    end

    def live_fields = collection.retrieve['fields']

    # 0.1.x declared every field but collection_ids.
    def create_collection_as_0_1_did
      collection.delete rescue nil
      legacy = schema.definition(provider.collection_name)
      legacy[:fields] = legacy[:fields].reject { |f| f[:name] == 'collection_ids' }
      provider.client.collections.create(legacy)
    end

    def capture_log(level)
      messages = []
      logger = Logger.new(File::NULL)
      allow(logger).to receive(level) { |msg = nil, &blk| messages << (msg || blk&.call) }
      allow(Rails).to receive(:logger).and_return(logger)
      messages
    end

    it 'does not raise, and leaves an up-to-date collection as it is' do
      expect { provider.ensure_index_settings! }.not_to raise_error
      expect(live_fields.map { |f| f['name'] })
        .to match_array(schema.definition(provider.collection_name)[:fields].map { |f| f[:name] })
    end

    # The comparison reads types as Typesense reports them back. A collection
    # just created from the definition must compare equal, or every reindex
    # would warn about fields that are fine.
    it 'finds no missing field and no type mismatch on a collection it just created' do
      expect(schema.missing_fields(live_fields)).to eq([])
      expect(schema.type_mismatches(live_fields)).to eq([])
    end

    it 'adds the fields a collection created by an earlier release lacks, as declared' do
      create_collection_as_0_1_did
      expect(live_fields.map { |f| f['name'] }).not_to include('collection_ids')

      provider.ensure_index_settings!

      expect(live_fields.find { |f| f['name'] == 'collection_ids' })
        .to include('type' => 'string[]', 'optional' => true, 'facet' => false)
    end

    it 'keeps the documents already in the collection' do
      create_collection_as_0_1_did
      provider.index_batch([doc('prod_kept')])

      provider.ensure_index_settings!

      expect(collection.documents['prod_kept_en_USD'].retrieve['product_id']).to eq('prod_kept')
    end

    it 'makes the added field filterable once documents carry it' do
      create_collection_as_0_1_did
      provider.ensure_index_settings!
      provider.index_batch([doc('prod_in', 'collection_ids' => %w[coll_a]),
                            doc('prod_out', 'collection_ids' => %w[coll_b])])

      found = collection.documents.search(q: '*', query_by: 'name', filter_by: 'collection_ids:=coll_a')

      expect(found['hits'].map { |h| h['document']['product_id'] }).to eq(%w[prod_in])
    end

    # The upgrade path the README prescribes: bump, reindex, and a collection
    # listing filters again instead of failing on an unknown field.
    context 'on Spree 6.x', if: SpreeTypesense.spree_6? do
      it 'serves an in_collection listing after the reindex adds the field' do
        create_collection_as_0_1_did
        allow(provider).to receive(:locale).and_return('en')
        allow(provider).to receive(:currency).and_return('USD')

        provider.ensure_index_settings!
        provider.index_batch([doc('prod_in', 'collection_ids' => %w[coll_a]),
                              doc('prod_out', 'collection_ids' => %w[coll_b])])
        result = provider.search_and_filter(scope: FakeScope.new(%w[prod_in prod_out]),
                                            filters: { 'in_collection' => 'coll_a' }, sort: 'price')

        expect(result.products.map(&:prefixed_id)).to eq(%w[prod_in])
        expect(result.total_count).to eq(1)
      end
    end

    # Typesense cannot retype a field in place. Say which field, and what to
    # do, rather than leaving the operator to find out from failed imports.
    it 'warns, naming the field and the remedy, when a live field has another type, and leaves it' do
      collection.delete rescue nil
      drifted = schema.definition(provider.collection_name)
      drifted[:fields] = drifted[:fields].map { |f| f[:name] == 'units_sold_count' ? f.merge(type: 'int64') : f }
      provider.client.collections.create(drifted)
      warnings = capture_log(:warn)

      provider.ensure_index_settings!

      expect(warnings.join(' ')).to include('units_sold_count', 'int64', 'int32', 'drop', 'reindex')
      expect(live_fields.find { |f| f['name'] == 'units_sold_count' }['type']).to eq('int64')
    end
  end

  it 'indexes a batch and makes documents retrievable' do
    provider.index_batch([
      { 'id' => 'prod_a_en_USD', 'product_id' => 'prod_a', 'locale' => 'en',
        'currency' => 'USD', 'status' => 'active', 'name' => 'Herbal Extract',
        'price' => 39.0, 'in_stock' => true, 'store_ids' => ['1'],
        'discontinue_on' => 0, 'units_sold_count' => 0,
        'created_at' => '2024-01-01T00:00:00Z' }
    ])

    doc = provider.client.collections[provider.collection_name].documents['prod_a_en_USD'].retrieve
    expect(doc['product_id']).to eq('prod_a')
  end

  it 'indexes a product by delegating to the configured presenter' do
    product = FakeProduct.new('prod_c')
    presenter = instance_double(
      SpreeTypesense::ProductPresenter,
      call: [
        { 'id' => 'prod_c_en_USD', 'product_id' => 'prod_c', 'locale' => 'en',
          'currency' => 'USD', 'status' => 'active', 'name' => 'Delegated',
          'price' => 9.0, 'in_stock' => true, 'store_ids' => ['1'],
          'discontinue_on' => 0, 'units_sold_count' => 0,
          'created_at' => '2024-01-01T00:00:00Z' }
      ]
    )
    presenter_class = class_double('SpreeTypesense::ProductPresenter', new: presenter)
    allow(provider).to receive(:presenter_class).and_return(presenter_class)

    provider.index(product)

    doc = provider.client.collections[provider.collection_name].documents['prod_c_en_USD'].retrieve
    expect(doc['product_id']).to eq('prod_c')
  end

  # Typesense answers an import with HTTP 200 and a result line per document,
  # so a rejected document raises nothing on its own.
  describe 'a document Typesense rejects' do
    let(:valid) do
      { 'id' => 'prod_ok_en_USD', 'product_id' => 'prod_ok', 'locale' => 'en', 'currency' => 'USD',
        'status' => 'active', 'name' => 'Accepted', 'price' => 1.0, 'in_stock' => true, 'store_ids' => ['1'],
        'discontinue_on' => 0, 'units_sold_count' => 0, 'created_at' => '2024-01-01T00:00:00Z' }
    end
    # `name` is a required field.
    let(:invalid) { valid.merge('id' => 'prod_bad_en_USD', 'product_id' => 'prod_bad').except('name') }

    it 'raises an error naming it, after importing the rest of the batch' do
      expect { provider.index_batch([invalid, valid]) }
        .to raise_error(described_class::ImportError, /prod_bad_en_USD/) { |e|
          expect(e.failures.map { |f| f[:id] }).to eq(%w[prod_bad_en_USD])
          expect(e.failures.first[:error]).to include('name')
        }

      expect(provider.client.collections[provider.collection_name].documents['prod_ok_en_USD'].retrieve)
        .to include('product_id' => 'prod_ok')
    end
  end

  # One product is N documents (locale x currency). When it stops producing
  # one, say it lost a currency's price, re-indexing it must remove that copy
  # rather than leave it searchable in that market.
  describe '#index removing documents the product no longer produces' do
    let(:collection) { provider.client.collections[provider.collection_name] }

    def doc(product_id, locale, currency)
      { id: "#{product_id}_#{locale}_#{currency}", product_id: product_id, locale: locale, currency: currency,
        status: 'active', name: "Product #{product_id}", price: 1.0, in_stock: true, store_ids: ['1'],
        discontinue_on: 0, units_sold_count: 0, created_at: '2024-01-01T00:00:00Z' }
    end

    def present(product_id, documents)
      presenter_class = class_double('SpreeTypesense::ProductPresenter')
      allow(presenter_class).to receive(:new) { instance_double(SpreeTypesense::ProductPresenter, call: documents) }
      allow(provider).to receive(:presenter_class).and_return(presenter_class)
      provider.index(FakeProduct.new(product_id))
    end

    def stored_ids
      collection.documents.search(q: '*', query_by: 'name', per_page: 100)['hits'].map { |h| h['document']['id'] }
    end

    # en-US carries a hyphen, which the delete filter has to quote.
    before do
      provider.index_batch([doc('prod_x', 'en', 'USD'), doc('prod_x', 'en-US', 'USD'), doc('prod_x', 'de', 'EUR'),
                            doc('prod_y', 'de', 'EUR')])
    end

    it "deletes the product's documents it no longer produces, and keeps the rest" do
      present('prod_x', [doc('prod_x', 'en', 'USD'), doc('prod_x', 'en-US', 'USD')])

      expect(stored_ids).to contain_exactly('prod_x_en_USD', 'prod_x_en-US_USD', 'prod_y_de_EUR')
    end

    it 'deletes every document of a product that now produces none' do
      present('prod_x', [])

      expect(stored_ids).to contain_exactly('prod_y_de_EUR')
    end

    it 'leaves the documents alone when they are all still produced' do
      present('prod_x', [doc('prod_x', 'en', 'USD'), doc('prod_x', 'en-US', 'USD'), doc('prod_x', 'de', 'EUR')])

      expect(stored_ids).to contain_exactly('prod_x_en_USD', 'prod_x_en-US_USD', 'prod_x_de_EUR', 'prod_y_de_EUR')
    end
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

# What #ensure_index_settings! asks of Typesense when the collection already
# exists. The client is a double and no server is needed; the schema
# comparison is the real one. What Typesense then does with the PATCH is
# pinned against the server above.
RSpec.describe Spree::SearchProvider::Typesense, '#ensure_index_settings! requests' do
  let(:store)    { instance_double('Spree::Store', id: 1, code: 'shop') }
  let(:provider) { described_class.new(store) }
  let(:declared) { described_class::Schema.definition(provider.collection_name)[:fields] }
  let(:live_fields) { declared.map { |f| { 'name' => f[:name], 'type' => f[:type], 'optional' => !!f[:optional] } } }
  let(:existing) { instance_double(Typesense::Collection) }
  let(:altered)  { instance_double(Typesense::Collection, update: {}) }
  let(:logged)   { Hash.new { |h, k| h[k] = [] } }

  before do
    collections = instance_double(Typesense::Collections)
    allow(collections).to receive(:create).and_raise(Typesense::Error::ObjectAlreadyExists, 'already exists')
    allow(collections).to receive(:[]).with('products_shop').and_return(existing)
    allow(existing).to receive(:retrieve) { { 'name' => 'products_shop', 'fields' => live_fields } }
    allow(provider).to receive(:client).and_return(instance_double(Typesense::Client, collections: collections))
    allow(provider).to receive(:schema_client)
      .and_return(instance_double(Typesense::Client, collections: { 'products_shop' => altered }))

    logger = Logger.new(File::NULL)
    %i[info warn error].each do |level|
      allow(logger).to receive(level) { |msg = nil, &blk| logged[level] << (msg || blk&.call) }
    end
    allow(Rails).to receive(:logger).and_return(logger)
  end

  context 'when the collection lacks a declared field' do
    let(:live_fields) { super().reject { |f| f['name'] == 'collection_ids' } }

    it 'PATCHes the missing fields onto it, as declared' do
      provider.ensure_index_settings!

      expect(altered).to have_received(:update)
        .with(fields: [declared.find { |f| f[:name] == 'collection_ids' }])
    end

    it 'logs which fields it added' do
      provider.ensure_index_settings!

      expect(logged[:info].join(' ')).to include('collection_ids', 'products_shop')
    end

    # A reindex carrying on would index into a collection that still cannot
    # serve the new filters, and report success.
    it 'raises when the PATCH fails, rather than carrying on' do
      allow(altered).to receive(:update).and_raise(Typesense::Error::ObjectUnprocessable, 'rejected')

      expect { provider.ensure_index_settings! }.to raise_error(Typesense::Error::ObjectUnprocessable)
    end
  end

  it 'sends no PATCH when the collection has every declared field' do
    provider.ensure_index_settings!

    expect(altered).not_to have_received(:update)
  end

  context 'when a live field has another type' do
    let(:live_fields) do
      super().map { |f| f['name'] == 'units_sold_count' ? f.merge('type' => 'int64') : f }
    end

    it 'warns, naming the field, both types and the remedy, and does not try to change it' do
      provider.ensure_index_settings!

      expect(logged[:warn].join(' ')).to include('units_sold_count', 'int64', 'int32', 'drop', 'reindex')
      expect(altered).not_to have_received(:update)
    end
  end

  # Typesense blocks writes to the collection while it alters it and answers
  # only when done, and runs one alter at a time: a short timeout would give
  # up on a large collection mid-alter, and a retry would be refused.
  it 'alters through a client with a long timeout and no retries' do
    allow(provider).to receive(:schema_client).and_call_original

    config = provider.send(:schema_client).configuration

    expect(config.connection_timeout_seconds).to be >= 60
    expect(config.num_retries).to eq(0)
  end
end

# What indexing sends Typesense, and what it makes of the per-document results
# an import answers with. The client is a double, so no server is needed; the
# server-backed examples above pin what Typesense does with the same requests.
RSpec.describe Spree::SearchProvider::Typesense, 'indexing requests' do
  let(:store)     { instance_double('Spree::Store', id: 1, code: 'shop') }
  let(:provider)  { described_class.new(store) }
  let(:documents) { instance_double(Typesense::Documents, delete: { 'num_deleted' => 0 }) }
  let(:logged)    { Hash.new { |h, k| h[k] = [] } }

  def doc(id, product_id = id[/\Aprod_[^_]+/]) = { id: id, product_id: product_id, name: id }

  def import_results(*outcomes)
    outcomes.map { |o| o == :ok ? { 'success' => true } : { 'success' => false, 'error' => o, 'document' => '{}' } }
  end

  before do
    collection = instance_double(Typesense::Collection, documents: documents)
    allow(provider).to receive(:client)
      .and_return(instance_double(Typesense::Client, collections: { 'products_shop' => collection }))

    logger = Logger.new(File::NULL)
    %i[info warn error].each do |level|
      allow(logger).to receive(level) { |msg = nil, &blk| logged[level] << (msg || blk&.call) }
    end
    allow(Rails).to receive(:logger).and_return(logger)
  end

  describe '#index_batch' do
    let(:batch) { [doc('prod_a_en_USD'), doc('prod_b_en_USD'), doc('prod_c_en_USD')] }

    it "upserts the batch and returns Typesense's per-document results when all succeed" do
      allow(documents).to receive(:import).and_return(import_results(:ok, :ok, :ok))

      expect(provider.index_batch(batch)).to eq(import_results(:ok, :ok, :ok))
      expect(documents).to have_received(:import)
        .with(batch.map { |d| hash_including('id' => d[:id], 'available_on_i' => 0) }, action: 'upsert')
    end

    it 'raises once the batch is sent, naming every document Typesense rejected' do
      allow(documents).to receive(:import).and_return(import_results('Bad price.', :ok, 'No name.'))

      expect { provider.index_batch(batch) }.to raise_error(described_class::ImportError) { |e|
        expect(e.message).to include('prod_a_en_USD', 'prod_c_en_USD', 'products_shop')
        expect(e.message).not_to include('prod_b_en_USD')
        expect(e.failures).to eq([{ id: 'prod_a_en_USD', error: 'Bad price.' }, { id: 'prod_c_en_USD', error: 'No name.' }])
      }
      expect(documents).to have_received(:import).once
    end

    it 'logs each rejected document with its id and the error' do
      allow(documents).to receive(:import).and_return(import_results(:ok, 'Bad price.', :ok))

      provider.index_batch(batch) rescue described_class::ImportError

      expect(logged[:error].size).to eq(1)
      expect(logged[:error].first).to include('prod_b_en_USD', 'Bad price.')
    end

    # The job that runs #index retries on any error, so a rejected document is
    # retried; that is what raising is for. A long tail of ids stays readable.
    it 'keeps the message short when many documents fail, while #failures keeps them all' do
      many = (1..60).map { |i| doc("prod_#{i}_en_USD") }
      allow(documents).to receive(:import).and_return(import_results(*Array.new(60, 'Bad.')))

      expect { provider.index_batch(many) }.to raise_error(described_class::ImportError) { |e|
        expect(e.failures.size).to eq(60)
        expect(e.message).to include('60 documents', 'prod_1_en_USD', 'and 10 more')
        expect(e.message).not_to include('prod_60_en_USD')
      }
    end
  end

  describe '#index' do
    def index_producing(product_id, produced)
      presenter_class = class_double('SpreeTypesense::ProductPresenter')
      allow(presenter_class).to receive(:new) { instance_double(SpreeTypesense::ProductPresenter, call: produced) }
      allow(provider).to receive(:presenter_class).and_return(presenter_class)
      provider.index(FakeProduct.new(product_id))
    end

    it "deletes the product's documents whose ids it no longer produces, after upserting the rest" do
      allow(documents).to receive(:import).and_return(import_results(:ok, :ok))

      index_producing('prod_x', [doc('prod_x_en_USD'), doc('prod_x_en-US_USD')])

      expect(documents).to have_received(:import).ordered
      expect(documents).to have_received(:delete)
        .with(filter_by: 'product_id:=prod_x && id:!=[`prod_x_en_USD`,`prod_x_en-US_USD`]').ordered
    end

    it 'deletes all of its documents, and imports nothing, when the product produces none' do
      allow(documents).to receive(:import)

      index_producing('prod_x', [])

      expect(documents).not_to have_received(:import)
      expect(documents).to have_received(:delete).with(filter_by: 'product_id:=prod_x')
    end

    # The documents Typesense did take are current, so the stale ones still go;
    # the job then retries the rejected one.
    it 'still deletes stale documents when some new ones are rejected, then raises' do
      allow(documents).to receive(:import).and_return(import_results(:ok, 'Bad price.'))

      expect { index_producing('prod_x', [doc('prod_x_en_USD'), doc('prod_x_de_EUR')]) }
        .to raise_error(described_class::ImportError, /prod_x_de_EUR/)
      expect(documents).to have_received(:delete)
        .with(filter_by: 'product_id:=prod_x && id:!=[`prod_x_en_USD`,`prod_x_de_EUR`]')
    end

    # Unreachable: nothing was upserted, so nothing is known to be stale.
    it 'deletes nothing when the import itself fails' do
      allow(documents).to receive(:import).and_raise(Faraday::ConnectionFailed, 'refused')

      expect { index_producing('prod_x', [doc('prod_x_en_USD')]) }.to raise_error(Faraday::ConnectionFailed)
      expect(documents).not_to have_received(:delete)
    end

    # A backtick cannot be quoted in a filter value, so the id list cannot be
    # written safely; deleting nothing beats deleting the wrong documents.
    it 'deletes nothing, and warns, when a produced id holds a backtick' do
      allow(documents).to receive(:import).and_return(import_results(:ok, :ok))

      index_producing('prod_x', [doc('prod_x_en_USD'), doc('prod_x_en`x_USD')])

      expect(documents).not_to have_received(:delete)
      expect(logged[:warn].join(' ')).to include('prod_x', 'backtick')
    end

    it 'never lets a product id add a clause to the delete filter' do
      allow(documents).to receive(:import)

      index_producing('prod_x || product_id:=prod_y', [])

      expect(documents).to have_received(:delete).with(filter_by: 'product_id:=prod_xproduct_idprod_y')
    end
  end
end
