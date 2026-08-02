module SpreeTypesense
  class Engine < ::Rails::Engine
    engine_name 'spree_typesense'
    config.autoload_paths += %W[#{config.root}/app/models]
  end
end
