module Spree
  module SearchProvider
    class Typesense < Base
      module Facets
        module_function

        # Typesense returns an array; Meilisearch returns a hash keyed by field.
        # Normalise to the hash shape so the builders below read like upstream.
        def normalize(facet_counts)
          Array(facet_counts).each_with_object({}) do |facet, acc|
            acc[facet['field_name']] = facet['counts'].to_h { |c| [c['value'], c['count']] }
          end
        end

        # Order matters — it is the order the storefront renders filters in, and
        # mirrors meilisearch.rb#build_facet_response. No `.compact`: every
        # builder below returns a hash or is skipped by its guard, so a nil can
        # never reach the array. Re-add it if that stops being true.
        def build(distribution, currency:)
          facets = []
          facets << price_facet(distribution['price'], currency) if distribution['price'].present?
          facets << availability_facet(distribution['in_stock']) if distribution['in_stock'].present?
          facets.concat(option_facets(distribution['option_value_ids'])) if distribution['option_value_ids'].present?
          facets << category_facet(distribution['category_ids']) if distribution['category_ids'].present?
          facets
        end

        def price_facet(distribution, currency)
          amounts = distribution.keys.map(&:to_f)
          { id: 'price', type: 'price_range', min: amounts.min, max: amounts.max, currency: currency }
        end

        def availability_facet(distribution)
          {
            id: 'availability',
            type: 'availability',
            options: [
              { id: 'in_stock',     count: distribution['true']  || 0 },
              { id: 'out_of_stock', count: distribution['false'] || 0 }
            ]
          }
        end

        # ONE ENTRY PER OPTION TYPE (not per value), options sorted by position.
        # Needs the database for names, labels, positions and image URLs — the
        # search index only carries prefixed ids.
        def option_facets(distribution)
          option_values = lookup(Spree::OptionValue, distribution.keys) { |rel| rel.includes(:option_type).preload_associations_lazily }

          by_option_type = distribution.each_with_object({}) do |(prefixed_id, count), acc|
            # A stale index can name values that no longer exist — skip, never guess.
            option_value = option_values[prefixed_id] or next

            (acc[option_value.option_type] ||= []) << {
              id: option_value.prefixed_id,
              name: option_value.name,
              label: option_value.label,
              position: option_value.position,
              color_code: option_value.color_code,
              image_url: image_url(option_value),
              count: count
            }
          end

          by_option_type.map do |option_type, values|
            {
              id: option_type.prefixed_id,
              type: 'option',
              name: option_type.name,
              label: option_type.label,
              kind: option_type.kind,
              options: values.sort_by { |o| o[:position] }
            }
          end
        end

        # All categories collapse into ONE facet whose id is the literal
        # 'categories' — unlike options, which get one facet per type.
        def category_facet(distribution)
          categories = lookup(Spree::Taxon, distribution.keys)

          {
            id: 'categories',
            type: 'category',
            options: distribution.filter_map do |prefixed_id, count|
              category = categories[prefixed_id] or next

              { id: category.prefixed_id, name: category.name, permalink: category.permalink, count: count }
            end
          }
        end

        # Decode prefixed ids -> one query -> index back by prefixed id.
        def lookup(klass, prefixed_ids)
          raw_ids = prefixed_ids.filter_map { |pid| klass.decode_prefixed_id(pid) }
          relation = klass.where(id: raw_ids)
          relation = yield(relation) if block_given?
          relation.index_by(&:prefixed_id)
        end

        def image_url(option_value)
          return nil unless option_value.image&.attached?

          Rails.application.routes.url_helpers.cdn_image_url(option_value.image)
        end
      end
    end
  end
end
