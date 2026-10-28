require 'spree_core'
require 'typesense'
require 'spree_typesense/version'
require 'spree_typesense/engine'

module SpreeTypesense
  PRESENTER_CLASS_NAME = 'SpreeTypesense::ProductPresenter'.freeze

  module_function

  def spree_version
    Gem::Version.new(Spree.version)
  end

  # The one place the 5.x / 6.x split is decided. Spree 6.0 renamed taxons to
  # categories, metafields to custom fields and `presentation` to `label`, and
  # dropped the search document presenter from core. Each use of this predicate
  # sits where one of those renames forces different code.
  def spree_6?
    spree_version >= Gem::Version.new('6.0.0.a')
  end

  # Spree 6.0 keeps `Spree::Taxon` only as a deprecated alias that warns the
  # first time it is referenced, so name the class that version actually has.
  def category_class
    spree_6? ? Spree::Category : Spree::Taxon
  end

  # Spree 6.0 core ships no search document presenter
  # (`search_product_presenter: nil`); the indexing provider gem supplies one.
  # Same pattern as spree_meilisearch 6.0: register ours unless the application
  # already named its own. On 5.x core's default stays in place, and the
  # provider indexes with this gem's presenter anyway (see
  # Typesense#presenter_class).
  def register_search_product_presenter!
    return unless spree_6?
    return if Spree::Dependencies.overridden?(:search_product_presenter)

    Spree::Dependencies.search_product_presenter = PRESENTER_CLASS_NAME
  end
end
