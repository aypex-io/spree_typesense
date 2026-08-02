module Spree
  module SearchProvider
    class Typesense < Base
      def self.indexing_required?
        true
      end

      def ensure_index_settings!
        client.collections.create(Schema.definition(collection_name))
      rescue ::Typesense::Error::ObjectAlreadyExists
        nil
      end

      def index(product)
        docs = Array(presenter_class.new(product, store).call)
        index_batch(docs)
      end

      def index_batch(documents)
        return if documents.blank?

        client.collections[collection_name]
              .documents
              .import(documents, action: 'upsert')
      end

      def remove(product)
        remove_by_id(product.prefixed_id)
      end

      def search_and_filter(scope:, query: nil, filters: {}, sort: nil, page: 1, limit: 25)
        page  = [page.to_i, 1].max
        limit = limit.to_i.clamp(1, 100)

        result = execute_search(query: query, filters: filters, sort: sort, page: page, limit: limit)
        return empty_result(scope, page, limit) unless result

        product_ids = result['hits'].map { |h| h['document']['product_id'] }.uniq
        raw_ids = product_ids.filter_map { |pid| Spree::Product.decode_prefixed_id(pid) }

        # SECURITY: intersect with the authorized scope, preserving engine order.
        products = if raw_ids.any?
                     records = scope.where(id: raw_ids).reorder(nil).index_by(&:id)
                     raw_ids.filter_map { |id| records[id] }
                   else
                     scope.none
                   end

        SearchResult.new(products: products, total_count: result['found'] || 0,
                          pagy: build_pagy(result['found'] || 0, page, limit))
      end

      # Composite ids mean one product maps to N documents (locale × currency),
      # so delete by filter on product_id rather than by document id.
      def remove_by_id(prefixed_id)
        client.collections[collection_name]
              .documents
              .delete(filter_by: "product_id:=#{sanitize_prefixed_id(prefixed_id)}")
      rescue ::Typesense::Error::ObjectNotFound
        nil
      end

      def client
        @client ||= begin
          uri = URI.parse(ENV.fetch('TYPESENSE_URL'))
          ::Typesense::Client.new(
            nodes: [{ host: uri.host, port: uri.port, protocol: uri.scheme }],
            api_key: ENV.fetch('TYPESENSE_API_KEY'),
            connection_timeout_seconds: 5
          )
        end
      end

      def collection_name
        @collection_name ||= "products_#{store.code}"
      end

      private

      def execute_search(query:, filters:, sort:, page:, limit:, facet_by: nil)
        f = filters.respond_to?(:to_unsafe_h) ? filters.to_unsafe_h : (filters || {}).to_h
        f = f.transform_keys(&:to_s)
        option_ids = f.delete('with_option_value_ids')

        conditions = QueryBuilder.system_conditions(store: store, locale: locale, currency: currency)
        conditions += QueryBuilder.user_conditions(f)
        conditions += QueryBuilder.grouped_option_conditions(group_option_values_by_type(Array(option_ids)))

        params = {
          q: query.presence || '*',
          query_by: Schema::SEARCHABLE_FIELDS.join(','),
          filter_by: conditions.join(' && '),
          page: page,
          per_page: limit
        }
        params[:sort_by]  = QueryBuilder.sort_by(sort) if QueryBuilder.sort_by(sort)
        params[:facet_by] = facet_by if facet_by

        client.collections[collection_name].documents.search(params)
      rescue ::Typesense::Error::Error, Faraday::Error => e
        Rails.logger.warn { "[spree_typesense] search failed: #{e.class}: #{e.message}. Run `rake spree:search:reindex`." }
        Rails.error.report(e, handled: true, context: { collection: collection_name, query: query })
        nil
      end

      # Mirrors meilisearch.rb#group_option_values_by_type. Hits the DB.
      def group_option_values_by_type(prefixed_ids)
        ids = prefixed_ids.flatten.compact.select { |id| QueryBuilder.valid_id?(id) }
        return {} if ids.empty?

        raw = ids.filter_map { |id| Spree::OptionValue.decode_prefixed_id(id) }
        Spree::OptionValue.where(id: raw).group_by(&:option_type_id)
                          .transform_values { |ovs| ovs.map(&:prefixed_id) }
      end

      def empty_result(scope, page, limit)
        SearchResult.new(products: scope.none, total_count: 0, pagy: build_pagy(0, page, limit))
      end

      def build_pagy(count, page, limit)
        Pagy::Offset.new(count: count, page: page, limit: limit)
      end

      def presenter_class
        # Configurable dependency, exactly as the Meilisearch provider resolves it.
        Spree::Dependencies.search_product_presenter_class
      end

      # `remove_by_id` is public and reached via Spree's RemoveJob (ActiveJob
      # serialisation, not a guaranteed well-formed id), so strip anything
      # that isn't part of a legitimate prefixed id before it lands in a
      # Typesense filter expression — mirrors the Meilisearch provider's guard.
      def sanitize_prefixed_id(value)
        value.to_s.gsub(/[^a-zA-Z0-9_]/, '')
      end
    end
  end
end
