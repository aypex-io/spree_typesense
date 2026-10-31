# Stands in for Typesense::Client in specs about what the provider ASKS
# Typesense: it records each search and multi_search, and answers with
# whatever the block returns, or raises what it raises. Specs about what
# Typesense DOES with a request run against the real server instead.
#
#   client = RecordingTypesenseClient.new { |kind, params| { 'found' => 0, 'hits' => [] } }
#   allow(provider).to receive(:client).and_return(client)
#   provider.search_and_filter(...)
#   client.searches.first[:filter_by]
class RecordingTypesenseClient
  EMPTY_RESULT = { 'found' => 0, 'hits' => [], 'facet_counts' => [] }.freeze

  attr_reader :requests

  def initialize(&responder)
    @requests = []
    @responder = responder || ->(kind, params) { kind == :multi_search ? { 'results' => params[:searches].map { EMPTY_RESULT } } : EMPTY_RESULT }
  end

  def collections = Hash.new { |hash, name| hash[name] = Collection.new(self, name) }

  def multi_search = MultiSearch.new(self)

  def searches = requests.select { |kind, _| kind == :search }.map(&:last)

  def record(kind, params)
    requests << [kind, params]
    @responder.call(kind, params)
  end

  Collection = Struct.new(:client, :name) do
    def documents = Documents.new(client)
  end

  Documents = Struct.new(:client) do
    def search(params) = client.record(:search, params)
  end

  MultiSearch = Struct.new(:client) do
    def perform(body, _query_params = {}) = client.record(:multi_search, body)
  end
end
