require 'bundler/setup'
require 'spree_typesense'

# This gem's specs run standalone (no host Rails app boots the engine's Zeitwerk
# autoloader), so Spree::SearchProvider::Base — which spree_core normally makes
# available via its own engine's autoload paths — never gets defined. Load it
# explicitly, then eager-require this gem's own app/models the same way a real
# host app's autoloader would.
#
# Which core files exist depends on the version under test, so pick them by
# version rather than probing the filesystem: 6.0 removed core's search
# presenter, and added the custom-field schema and rich-text helper that Base
# and this gem's presenter use there.
spree_core_root = Gem::Specification.find_by_name('spree_core').gem_dir
require File.join(spree_core_root, 'app/models/spree/search_provider/base')
require File.join(spree_core_root, 'app/models/spree/search_provider/search_result')
require File.join(spree_core_root, 'app/models/spree/search_provider/filters_result')
if SpreeTypesense.spree_6?
  require File.join(spree_core_root, 'app/services/spree/search_provider/custom_field_schema')
  require File.join(spree_core_root, 'app/helpers/spree/rich_text_helper')
else
  # Only to compare this gem's presenter against core's, field for field.
  require File.join(spree_core_root, 'app/presenters/spree/search_provider/product_presenter')
end
require File.join(spree_core_root, 'app/models/spree/search_provider/database')
# The request context the provider reads the current channel from, as core's
# storefront scope does. Its fallbacks reach for Spree::Store, which this
# suite does not have, so every example starts with no channel (see below).
require File.join(spree_core_root, 'app/models/spree/current')

Dir[File.join(__dir__, '..', 'app/{models,presenters}/**/*.rb')].sort.each { |f| require f }
Dir[File.join(__dir__, 'support/**/*.rb')].sort.each { |f| require f }

# spree_core's engine defines both of these in an initializer, which never runs
# here. Build them the same way it does. `Spree::Dependencies` starts at core's
# defaults with nothing overridden, as in a freshly booted app.
module Spree
  Dependencies = Spree::Core::Dependencies.new unless const_defined?(:Dependencies, false)
  Deprecation = ActiveSupport::Deprecation.new('6.0', 'Spree') unless const_defined?(:Deprecation, false)
end

# Any Spree deprecation warning raised while the suite runs fails the example
# that triggered it. On 6.x that is how the gem proves it never touches
# Spree::Taxon, #taxons, #metafields, #metafield_schema or
# #variants_including_master.
Spree::Deprecation.behavior = :raise

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

  # The category model is Spree::Taxon on 5.x and Spree::Category on 6.x. Only
  # the one the version under test has is defined, so a stray reference to
  # Spree::Taxon on 6.x fails with NameError instead of passing silently.
  category = Class.new do
    def self.decode_prefixed_id(prefixed_id_string)
      return nil if prefixed_id_string.to_s.empty?

      prefixed_id_string.to_s.split('_', 2).last
    end
  end
  const_set(SpreeTypesense.spree_6? ? :Category : :Taxon, category)
end

def category_class = SpreeTypesense.category_class

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

# Stub `Spree::OptionValue.where(id:)` / `category_class.where(id:)` to return the
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

  # Core's scope needs the database to say which products have one variant
  # carrying every selected option type, so an example that reaches it must
  # say which products survive.
  def with_option_value_ids(*)
    raise NotImplementedError, 'stub FakeScope#with_option_value_ids with the products that survive'
  end
end

# The provider's error path calls `Rails.logger.warn` and `Rails.error.report`,
# both of which a real host app always provides but which are nil when no Rails
# app is booted. Supply null implementations so specs exercise the REAL rescue
# path end-to-end — making the production code nil-tolerant instead would be
# tailoring the gem to an artefact of this suite.
require 'logger'

module Spree
  module SearchProvider
    NULL_ERROR_REPORTER = Object.new
    def NULL_ERROR_REPORTER.report(*, **); end
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.before do
    allow(Rails).to receive(:logger).and_return(Logger.new(File::NULL))
    allow(Rails).to receive(:error).and_return(Spree::SearchProvider::NULL_ERROR_REPORTER)
    # No channel unless an example sets one: the real fallback (the store's
    # default channel) needs Spree::Store.
    allow(Spree::Current).to receive(:channel).and_return(nil)
  end

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
