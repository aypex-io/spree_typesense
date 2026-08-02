module Spree
  module SearchProvider
    class Typesense < Base
      module Schema
        SEARCHABLE_FIELDS = %w[name description sku brand].freeze
        FACET_FIELDS      = %w[option_value_ids taxon_ids brand currency locale status].freeze
        SORT_FIELDS       = %w[price created_at best_selling_score].freeze

        module_function

        def definition(collection_name)
          {
            name: collection_name,
            # Sort on price by default; Typesense requires a default sorting field.
            default_sorting_field: 'created_at',
            fields: [
              # Composite doc id (prod_abc_en_USD) is Typesense's own `id`.
              { name: 'product_id', type: 'string', facet: false },
              { name: 'locale',     type: 'string', facet: true },
              { name: 'currency',   type: 'string', facet: true },
              { name: 'status',     type: 'string', facet: true },

              { name: 'name',        type: 'string', facet: false },
              { name: 'description', type: 'string', facet: false, optional: true },
              { name: 'sku',         type: 'string', facet: false, optional: true },
              { name: 'brand',       type: 'string', facet: true,  optional: true },

              { name: 'option_value_ids', type: 'string[]', facet: true, optional: true },
              { name: 'taxon_ids',        type: 'string[]', facet: true, optional: true },

              { name: 'price',              type: 'float',  facet: false },
              { name: 'created_at',         type: 'int64',  facet: false },
              { name: 'best_selling_score', type: 'int32',  facet: false, optional: true }
            ]
          }
        end
      end
    end
  end
end
