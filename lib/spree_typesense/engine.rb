module SpreeTypesense
  class Engine < ::Rails::Engine
    engine_name 'spree_typesense'
    config.autoload_paths += %W[#{config.root}/app/models]

    # After initialize, so an application's own
    # `Spree::Dependencies.search_product_presenter = ...` (set in an
    # initializer) is already recorded and wins.
    config.after_initialize do
      SpreeTypesense.register_search_product_presenter!
    end
  end
end
