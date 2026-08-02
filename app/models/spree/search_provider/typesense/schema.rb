module Spree
  module SearchProvider
    class Typesense < Base
      module Schema
        # Transcribed from spree_core ProductPresenter#build_document.
        # Do not add fields the presenter does not emit.
        SEARCHABLE_FIELDS = %w[name description sku option_values category_names tags].freeze

        # Mirrors meilisearch.rb#facet_attributes (== filterable_attributes).
        FACET_FIELDS = %w[
          product_id status in_stock store_ids channel_ids locale currency
          price category_ids tags option_value_ids preorder
        ].freeze

        SORT_FIELDS = %w[name price created_at available_on units_sold_count].freeze

        # MUST be numeric — Typesense rejects a string default_sorting_field.
        # created_at is an ISO8601 string, so units_sold_count serves instead.
        DEFAULT_SORTING_FIELD = 'units_sold_count'.freeze

        module_function

        def definition(collection_name)
          {
            name: collection_name,
            default_sorting_field: DEFAULT_SORTING_FIELD,
            fields: [
              { name: 'product_id', type: 'string',  facet: true },
              { name: 'locale',     type: 'string',  facet: true },
              { name: 'currency',   type: 'string',  facet: true },

              { name: 'name',        type: 'string', facet: false, sort: true },
              { name: 'description', type: 'string', facet: false, optional: true },
              { name: 'slug',        type: 'string', facet: false, optional: true },

              { name: 'price',            type: 'float', facet: true,  optional: true, sort: true },
              { name: 'compare_at_price', type: 'float', facet: false, optional: true },

              { name: 'status',   type: 'string', facet: true },
              { name: 'sku',      type: 'string', facet: false, optional: true },
              { name: 'in_stock', type: 'bool',   facet: true },

              { name: 'store_ids',      type: 'string[]', facet: true },
              { name: 'channel_ids',    type: 'string[]', facet: true, optional: true },
              { name: 'discontinue_on', type: 'int64',    facet: false },

              { name: 'category_ids',   type: 'string[]', facet: true, optional: true },
              { name: 'category_names', type: 'string[]', facet: false, optional: true },

              { name: 'option_type_ids',   type: 'string[]', facet: false, optional: true },
              { name: 'option_type_names', type: 'string[]', facet: false, optional: true },
              { name: 'option_value_ids',  type: 'string[]', facet: true,  optional: true },
              { name: 'option_values',     type: 'string[]', facet: false, optional: true },

              { name: 'tags',             type: 'string[]', facet: true, optional: true },
              { name: 'units_sold_count', type: 'int32',    facet: false },

              # ISO8601 STRINGS. They sort lexicographically in chronological
              # order, so sort: true is sound. Never retype these to int.
              { name: 'available_on', type: 'string', facet: false, optional: true, sort: true },
              { name: 'created_at',   type: 'string', facet: false, optional: true, sort: true },
              { name: 'updated_at',   type: 'string', facet: false, optional: true, sort: true },

              # DERIVED, not emitted by the presenter. Typesense silently returns ZERO
              # results for range filters (<=, >) on string fields — verified against
              # v30.2 — so availability filtering needs an int64. Derived at index time;
              # 0 means "always available", which also removes the need for upstream's
              # NOT EXISTS / IS NULL three-way clause.
              { name: 'available_on_i', type: 'int64', facet: false },

              # spree_core 5.5.1 (what TKF runs, and what this gem develops
              # against) does NOT emit this field. spree_core 5.6+ does
              # (product.preorder?). Declared optional so the collection
              # stays valid whichever version's documents arrive.
              { name: 'preorder', type: 'bool', facet: true, optional: true }
            ]
          }
        end
      end
    end
  end
end
