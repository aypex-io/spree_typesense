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

        # 6b appends option and category facets here.
        def build(distribution, currency:)
          facets = []
          facets << price_facet(distribution['price'], currency) if distribution['price'].present?
          facets << availability_facet(distribution['in_stock']) if distribution['in_stock'].present?
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
      end
    end
  end
end
