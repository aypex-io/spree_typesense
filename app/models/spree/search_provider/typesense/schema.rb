module Spree
  module SearchProvider
    class Typesense < Base
      module Schema
        # Transcribed from SpreeTypesense::ProductPresenter#build_document (a
        # port of spree_core 5.6.1's, which 6.0 removed from core). Every
        # supported Spree version emits the same named fields, plus
        # `collection_ids` on 6.x; only their sources differ. `cf_*` keys are
        # dynamic and left undeclared — Typesense stores them without indexing
        # them, so they can be neither searched, filtered nor sorted on.
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
              # Spree 6.x only, for the in_collection filter. Typesense filters
              # on any indexed field, so no facet: collection facets are not
              # offered. Optional because 5.x documents never carry it.
              { name: 'collection_ids', type: 'string[]', facet: false, optional: true },

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

              # Not emitted on spree_core 5.5.x, whose products have no
              # preorder?. Emitted on 5.6+ and 6.x (product.preorder?).
              # Declared optional so the collection stays valid whichever
              # version's documents arrive.
              { name: 'preorder', type: 'bool', facet: true, optional: true }
            ]
          }
        end

        # The fields #definition declares that a live collection lacks, as
        # their declared definitions, ready to PATCH onto it. A collection
        # created by an earlier release gains them in place this way.
        #
        # @param live_fields [Array<Hash>] the `fields` of a retrieved collection
        # @return [Array<Hash>]
        def missing_fields(live_fields)
          live_names = live_fields.map { |f| f['name'] }
          declared_fields.reject { |f| live_names.include?(f[:name]) }
        end

        # Fields the live collection declares with a different type from
        # #definition. Typesense cannot change a field's type in place, so
        # these need the collection dropped and rebuilt.
        #
        # @param live_fields [Array<Hash>] the `fields` of a retrieved collection
        # @return [Array<Hash>] `{ name:, live_type:, type: }` per field
        def type_mismatches(live_fields)
          live_types = live_fields.to_h { |f| [f['name'], f['type']] }
          declared_fields.filter_map do |f|
            live_type = live_types[f[:name]]
            { name: f[:name], live_type: live_type, type: f[:type] } if live_type && live_type != f[:type]
          end
        end

        def declared_fields = definition(nil)[:fields]
      end
    end
  end
end
