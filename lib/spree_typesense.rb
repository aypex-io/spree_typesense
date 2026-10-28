require 'spree_core'
require 'typesense'
require 'spree_typesense/version'
require 'spree_typesense/engine'

module SpreeTypesense
  PRESENTER_CLASS_NAME = 'SpreeTypesense::ProductPresenter'.freeze

  module_function

  # Memoised, as is spree_6?: the installed spree_core cannot change while the
  # process runs, and spree_6? is asked per document and per option value on
  # the reindex path.
  def spree_version
    @spree_version ||= Gem::Version.new(Spree.version)
  end

  # The one place the 5.x / 6.x split is decided. Spree 6.0 renamed taxons to
  # categories, metafields to custom fields and `presentation` to `label`, and
  # dropped the search document presenter from core. Each use of this predicate
  # sits where one of those renames forces different code.
  def spree_6?
    return @spree_6 if defined?(@spree_6)

    @spree_6 = spree_version >= Gem::Version.new('6.0.0.a')
  end

  # Spree 6.0 keeps `Spree::Taxon` only as a deprecated alias that warns the
  # first time it is referenced, so name the class that version actually has.
  def category_class
    spree_6? ? Spree::Category : Spree::Taxon
  end

  # Spree 6.0 core ships no search document presenter
  # (`search_product_presenter: nil`); the indexing provider gem supplies one.
  # Same pattern as spree_meilisearch 6.0: register ours unless the application,
  # or another search gem, already named one. On 5.x core's default stays in
  # place, and the provider indexes with this gem's presenter anyway (see
  # Typesense#presenter_class).
  #
  # Only when Typesense is the selected `Spree.search_provider`, though. There
  # is one presenter setting for every installed search gem, so with
  # spree_meilisearch installed too, registering ours while Meilisearch is the
  # selected provider would make spree_meilisearch (whose engine skips
  # registering once the setting is overridden) index with our documents.
  def register_search_product_presenter!
    return unless spree_6?
    return unless typesense_selected?
    return if Spree::Dependencies.overridden?(:search_product_presenter)

    Spree::Dependencies.search_product_presenter = PRESENTER_CLASS_NAME
  end

  def typesense_selected?
    provider = Spree.search_provider.to_s.safe_constantize
    provider.is_a?(Class) && provider <= Spree::SearchProvider::Typesense
  end
end
