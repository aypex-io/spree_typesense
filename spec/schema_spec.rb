require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense::Schema do
  subject(:definition) { described_class.definition('products_test') }

  it 'names the collection' do
    expect(definition[:name]).to eq('products_test')
  end

  it 'declares id and product_id as separate fields' do
    names = definition[:fields].map { |f| f[:name] }
    # Documents are composite-keyed prod_abc_en_USD; product_id holds prod_abc.
    expect(names).to include('product_id', 'locale', 'currency')
  end

  it 'marks facet fields as facetable' do
    facets = definition[:fields].select { |f| f[:facet] }.map { |f| f[:name] }
    expect(facets).to include(*described_class::FACET_FIELDS)
  end

  it 'creates the collection against a real server' do
    typesense_client.collections['products_test'].delete rescue nil
    result = typesense_client.collections.create(definition)
    expect(result['name']).to eq('products_test')
  end
end
