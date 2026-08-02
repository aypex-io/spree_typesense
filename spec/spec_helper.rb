require 'bundler/setup'
require 'spree_typesense'

# This gem's specs run standalone (no host Rails app boots the engine's Zeitwerk
# autoloader), so Spree::SearchProvider::Base — which spree_core normally makes
# available via its own engine's autoload paths — never gets defined. Load it
# explicitly, then eager-require this gem's own app/models the same way a real
# host app's autoloader would.
spree_core_root = Gem::Specification.find_by_name('spree_core').gem_dir
require File.join(spree_core_root, 'app/models/spree/search_provider/base')
require File.join(spree_core_root, 'app/models/spree/search_provider/search_result')
require File.join(spree_core_root, 'app/models/spree/search_provider/filters_result')
require File.join(spree_core_root, 'app/presenters/spree/search_provider/product_presenter')

Dir[File.join(__dir__, '..', 'app/models/**/*.rb')].sort.each { |f| require f }

# No ActiveRecord in this suite, so `Spree::Product` (normally an AR model
# from spree_core's own autoload paths) never gets defined. The provider only
# needs `.decode_prefixed_id` off it — stub just that, mirroring the real
# Spree::PrefixedId concern's split-on-underscore-then-decode shape closely
# enough for tests without pulling in ActiveRecord.
module Spree
  class Product
    def self.decode_prefixed_id(prefixed_id_string)
      return nil if prefixed_id_string.to_s.empty?

      prefixed_id_string.to_s.split('_', 2).last
    end
  end

  # Option/category facets need Spree lookups for names, labels, positions,
  # permalinks and image URLs. There is no ActiveRecord in this suite, so these
  # classes exist only to be stubbed: `.decode_prefixed_id` behaves like the
  # real PrefixedId concern, and `.where` is stubbed per-example to return a
  # `FakeArRelation`. Typesense itself stays real.
  class OptionValue
    def self.decode_prefixed_id(prefixed_id_string)
      return nil if prefixed_id_string.to_s.empty?

      prefixed_id_string.to_s.split('_', 2).last
    end
  end

  class Taxon
    def self.decode_prefixed_id(prefixed_id_string)
      return nil if prefixed_id_string.to_s.empty?

      prefixed_id_string.to_s.split('_', 2).last
    end
  end
end

# The subset of ActiveRecord::Relation the facet builders actually call.
# `preload_associations_lazily` comes from ar_lazy_preload (a spree_core
# dependency) in a real host app.
class FakeArRelation
  def initialize(records)
    @records = records
  end

  def includes(*) = self
  def preload_associations_lazily = self
  def index_by(&block) = @records.index_by(&block)
  def pluck(*fields) = @records.map { |r| fields.map { |f| r.public_send(f) } }
  def to_a = @records
end

FakeImage = Struct.new(:attached, keyword_init: true) do
  def attached? = !!attached
end

FakeOptionType = Struct.new(:prefixed_id, :name, :label, :kind, keyword_init: true)

FakeOptionValue = Struct.new(
  :id, :prefixed_id, :name, :label, :position, :color_code, :option_type_id, :option_type, :image,
  keyword_init: true
)

FakeTaxon = Struct.new(:id, :prefixed_id, :name, :permalink, keyword_init: true)

# Stub `Spree::OptionValue.where(id:)` / `Spree::Taxon.where(id:)` to return the
# subset of `records` whose ids were asked for — the same filtering the real
# query would do, so a builder that ignores the id list cannot pass silently.
def stub_ar_lookup(klass, records)
  allow(klass).to receive(:where) do |args|
    wanted = Array(args[:id]).map(&:to_s)
    FakeArRelation.new(records.select { |r| wanted.include?(r.id.to_s) })
  end
end

# Stand-ins for the ActiveRecord::Relation `search_and_filter` receives as
# `scope:` — store-scoped, visibility-filtered, already-authorized products.
# `FakeScope.new(prefixed_ids)` is the set of products the caller is
# authorized to see; `#where(id:)` is the only AR method the provider calls
# on it, so that's the only method faked.
class FakeProduct
  attr_reader :id, :prefixed_id

  def initialize(prefixed_id)
    @prefixed_id = prefixed_id
    @id = Spree::Product.decode_prefixed_id(prefixed_id)
  end
end

class FakeRelation
  include Enumerable

  def initialize(products)
    @products = products
  end

  def each(&block) = @products.each(&block)
  def reorder(_arg) = self
  def index_by(&block) = @products.index_by(&block)
  def none = FakeRelation.new([])
  def empty? = @products.empty?
end

class FakeScope
  def initialize(prefixed_ids)
    @products = prefixed_ids.map { |pid| FakeProduct.new(pid) }
  end

  def where(id:)
    ids = Array(id)
    FakeRelation.new(@products.select { |p| ids.include?(p.id) })
  end

  def none
    FakeRelation.new([])
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.before(:suite) do
    # Fail loudly if no server — mocking a search engine tests nothing useful.
    typesense_client.health.retrieve
  rescue StandardError => e
    abort "Typesense unreachable at #{ENV.fetch('TYPESENSE_URL', 'http://localhost:8108')}: #{e.message}"
  end
end

def typesense_client
  uri = URI.parse(ENV.fetch('TYPESENSE_URL', 'http://localhost:8108'))
  Typesense::Client.new(
    nodes: [{ host: uri.host, port: uri.port, protocol: uri.scheme }],
    api_key: ENV.fetch('TYPESENSE_API_KEY', 'test-key'),
    connection_timeout_seconds: 5
  )
end
