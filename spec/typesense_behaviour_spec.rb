require 'spec_helper'

# Executable documentation of Typesense behaviours this gem depends on.
# These assert against the LIVE SERVER, deliberately not through our provider:
# if a Typesense upgrade changes any of them, this suite fails and tells you
# which assumption broke — before production finds out.
#
# Every example names the real defect it would have caught during the build.
RSpec.describe 'Typesense engine behaviours we rely on' do
  let(:coll) { 'behaviour_probe' }

  before do
    typesense_client.collections[coll].delete rescue nil
    typesense_client.collections.create(
      name: coll,
      default_sorting_field: 'n',
      fields: [
        { name: 'n',      type: 'int32' },
        { name: 'iso',    type: 'string', sort: true },
        { name: 'epoch',  type: 'int64' },
        { name: 'price',  type: 'float',    facet: true },
        { name: 'colour', type: 'string',   facet: true, optional: true },
        { name: 'tags',   type: 'string[]', facet: true, optional: true }
      ]
    )
  end

  after { typesense_client.collections[coll].delete rescue nil }

  def add(doc) = typesense_client.collections[coll].documents.create(doc)
  def search(params) = typesense_client.collections[coll].documents.search(params)

  # DIVERGENCE 1 — once made every search return zero results.
  # Meilisearch compares ISO8601 strings lexicographically; Typesense does not.
  # This is why the provider derives available_on_i (int64) at index time.
  describe 'range operators on string fields' do
    before { add('id' => '1', 'n' => 1, 'iso' => '2020-01-01T00:00:00Z', 'epoch' => 1_577_836_800, 'price' => 1.0) }

    it 'silently matches NOTHING on a string field, with no error raised' do
      result = search(q: '*', filter_by: 'iso:<=2026-08-02T00:00:00Z')
      expect(result['found']).to eq(0)
    end

    it 'works correctly on an int64 field' do
      result = search(q: '*', filter_by: 'epoch:<=1900000000')
      expect(result['found']).to eq(1)
    end
  end

  # DIVERGENCE 2 — once broke the price facet,
  # which derived min/max from facet KEYS.
  describe 'facet value truncation' do
    before { 15.times { |i| add('id' => i.to_s, 'n' => i, 'iso' => '2020-01-01T00:00:00Z', 'epoch' => 1, 'price' => (i + 1) * 7.5) } }

    it 'caps facet values at 10 by default and truncates silently' do
      facet = search(q: '*', facet_by: 'price')['facet_counts'].first
      expect(facet['counts'].length).to eq(10)
    end

    it 'returns more when max_facet_values is raised' do
      facet = search(q: '*', facet_by: 'price', max_facet_values: 100)['facet_counts'].first
      expect(facet['counts'].length).to eq(15)
    end

    # This is the escape hatch the price facet now uses.
    it 'reports EXACT min/max in stats even while counts are truncated' do
      facet = search(q: '*', facet_by: 'price')['facet_counts'].first
      expect(facet['stats']['min']).to eq(7.5)
      expect(facet['stats']['max']).to eq(112.5)
    end

    it 'narrows stats to the filtered set, so the price slider still tracks filters' do
      facet = search(q: '*', facet_by: 'price', filter_by: 'price:>=50')['facet_counts'].first
      expect(facet['stats']['min']).to be >= 50
    end

    # Why max_facet_values is still needed for string facets.
    it 'gives NON-numeric facets a stats block with no min/max' do
      facet = search(q: '*', facet_by: 'tags')['facet_counts'].first
      expect(facet['stats']).not_to have_key('min')
    end
  end

  # DIVERGENCE 3 — the disjunctive merge must cope with ABSENT, not zero.
  # Meilisearch reports a filtered-out value as 0; Typesense omits it.
  describe 'zero-count facet values' do
    before do
      add('id' => '1', 'n' => 1, 'iso' => 'x', 'epoch' => 1, 'price' => 1.0, 'colour' => 'red')
      add('id' => '2', 'n' => 2, 'iso' => 'x', 'epoch' => 1, 'price' => 1.0, 'colour' => 'blue')
    end

    it 'omits a filtered-out value entirely rather than reporting count 0' do
      facet = search(q: '*', facet_by: 'colour', filter_by: 'colour:=red')['facet_counts'].first
      values = facet['counts'].map { |c| c['value'] }
      expect(values).to include('red')
      expect(values).not_to include('blue')   # ABSENT, not present-with-zero
    end
  end

  # DIVERGENCE 4 — a failing sub-search does NOT raise. Missing this would have
  # silently degraded facets to empty during the original build.
  describe 'multi_search error reporting' do
    before { add('id' => '1', 'n' => 1, 'iso' => 'x', 'epoch' => 1, 'price' => 1.0) }

    it 'returns per-result error bodies instead of raising' do
      response = typesense_client.multi_search.perform(
        { searches: [
          { collection: coll, q: '*' },
          { collection: coll, q: '*', filter_by: 'nonexistent_field:=1' }
        ] }, {}
      )
      expect(response['results'][0]).not_to have_key('error')
      expect(response['results'][1]).to have_key('error')
    end
  end

  # DIVERGENCE 5 — the dead-rescue bug. `::Typesense::Error::Error` does not
  # exist, so `rescue` clauses naming it were invisible dead code and every API
  # failure escaped as NameError. Survived three task reviews.
  describe 'the client error class hierarchy' do
    it 'has NO ::Typesense::Error::Error constant' do
      expect { ::Typesense::Error::Error }.to raise_error(NameError)
    end

    it 'raises a ::Typesense::Error subclass for a missing collection' do
      expect { typesense_client.collections['definitely_missing'].documents.search(q: '*') }
        .to raise_error(::Typesense::Error)
    end
  end
end
