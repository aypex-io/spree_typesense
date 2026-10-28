module Spree
  module SearchProvider
    class Typesense < Base
      AVAILABLE_SORT_OPTIONS = %w[price -price name -name -available_on available_on best_selling].freeze

      # Spree 5.6's Spree::Api::V3::ProductFilterSortOptionSerializer declares
      # `attributes :id, :label` and raises KeyError when :label is absent.
      # Spree 5.5 only read :id, so the extra key is harmless there — this one
      # shape satisfies both, and 6.0 reads the same keys, which the gemspec
      # range (>= 5.5, < 7.0) requires.
      #
      # NOTE: 5.6 also appends metafield-driven sort options
      # (`metafield_schema.sort_options`), and 6.0 custom-field ones
      # (`custom_field_schema.sort_options`). We do not yet surface those, so a
      # store using custom-field sorts will not see them under this provider.
      def sort_options_payload
        AVAILABLE_SORT_OPTIONS.map { |id| { id: id, label: nil } }
      end
      DEFAULT_SORT = 'manual'.freeze

      # Typesense defaults to 10 facet values per field and truncates silently.
      # Needed by option/category facets; the price range reads stats instead.
      MAX_FACET_VALUES = 100

      def self.indexing_required?
        true
      end

      def ensure_index_settings!
        client.collections.create(Schema.definition(collection_name))
      rescue ::Typesense::Error::ObjectAlreadyExists
        log_schema_drift_warning
        nil
      end

      # Mirrors meilisearch.rb#reindex: default scope is store.products (not
      # Spree::Product.where(store_id:)), batch size 500, deterministic order,
      # lazy-preloaded associations. Returns the number of DOCUMENTS indexed
      # (not products — one product can emit N locale x currency documents).
      def reindex(scope = nil)
        scope ||= store.products
        ensure_index_settings!

        indexed = 0
        scope.reorder(id: :asc).preload_associations_lazily.find_in_batches(batch_size: 500) do |batch|
          documents = batch.flat_map { |product| presenter_class.new(product, store).call }
          next if documents.empty?

          index_batch(documents)
          indexed += documents.size
          Rails.logger.info { "[spree_typesense] indexed #{documents.size} (#{indexed} total) into #{collection_name}" }
        end

        Rails.logger.info { "[spree_typesense] reindex complete: #{indexed} documents" }
        indexed
      end

      def index(product)
        docs = Array(presenter_class.new(product, store).call)
        index_batch(docs)
      end

      def index_batch(documents)
        return if documents.blank?

        client.collections[collection_name]
              .documents
              .import(documents.map { |d| derive_fields(d) }, action: 'upsert')
      end

      def remove(product)
        remove_by_id(product.prefixed_id)
      end

      # Public entry point. Delegates to the real Typesense search path and
      # degrades to the Database provider when Typesense itself is
      # unreachable, rather than 500ing or silently returning zero results.
      #
      # NOTE: execute_search/execute_multi_search re-raise connection-level
      # failures (see below) specifically so they can reach this rescue —
      # their own broad `rescue ::Typesense::Error, Faraday::Error` would
      # otherwise swallow Faraday::ConnectionFailed itself (it IS-A
      # Faraday::Error) and this clause would be permanently unreachable.
      def search_and_filter(scope:, query: nil, filters: {}, sort: nil, page: 1, limit: 25)
        search_with_typesense(scope: scope, query: query, filters: filters, sort: sort, page: page, limit: limit)
      rescue Faraday::ConnectionFailed, Errno::ECONNREFUSED => e
        Rails.logger.error { "[spree_typesense] unreachable, degrading to Database provider: #{e.message}" }
        fallback_provider.search_and_filter(
          scope: scope, query: query, filters: filters, sort: sort, page: page, limit: limit
        )
      end

      def search_with_typesense(scope:, query: nil, filters: {}, sort: nil, page: 1, limit: 25)
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

      def filters(scope:, query: nil, filters: {})
        result, distribution, stats = execute_faceted_search(query: query, filters: filters)
        return empty_filters_result unless result

        FiltersResult.new(
          filters: Facets.build(distribution, currency: currency, stats: stats),
          sort_options: sort_options_payload,
          default_sort: DEFAULT_SORT,
          total_count: result['found'] || 0
        )
      # `filters` has no Database-provider equivalent to degrade to (facets
      # are a Typesense-only concept here), so — unlike search_and_filter —
      # connection failures degrade to an empty facet set rather than
      # propagating. Needed because execute_search/execute_multi_search now
      # deliberately re-raise these for search_and_filter's benefit; without
      # this rescue a Typesense outage would turn a graceful empty-facets
      # response into an unhandled 500 here.
      rescue Faraday::ConnectionFailed, Errno::ECONNREFUSED => e
        Rails.logger.error { "[spree_typesense] unreachable while computing filters, returning empty: #{e.message}" }
        empty_filters_result
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
        base, grouped = build_conditions(filters)
        conditions = base + QueryBuilder.grouped_option_conditions(grouped)

        client.collections[collection_name].documents.search(
          search_params(query: query, conditions: conditions, sort: sort, page: page, limit: limit, facet_by: facet_by)
        )
      rescue Faraday::ConnectionFailed, Errno::ECONNREFUSED
        # Let the caller's degradation wrapper handle this — see the note on
        # +search_and_filter+. Deliberately NOT caught by the broader rescue
        # below, since Faraday::ConnectionFailed IS-A Faraday::Error.
        raise
      rescue ::Typesense::Error, Faraday::Error => e
        report_search_failure(e, query)
        nil
      end

      # Faceted read path. Returns [main_result, distribution, stats], or nil.
      # `stats` always comes from the MAIN query — it covers numeric fields
      # (price), which disjunctive relaxation never touches.
      #
      # DISJUNCTIVE FACETING: with option values selected, the counts for each
      # selected option type must be computed with THAT type's own filter
      # removed — otherwise picking "Red" reports every other colour as zero
      # and the shopper can never widen their choice. That needs one extra
      # query per selected type, so it goes through multi_search. With nothing
      # selected there is nothing to relax, so we stay on the single-query path
      # rather than pay for a multi_search on every request.
      def execute_faceted_search(query:, filters:)
        base, grouped = build_conditions(filters)
        facet_by = Schema::FACET_FIELDS.join(',')

        if grouped.empty?
          result = execute_search(query: query, filters: filters, sort: nil, page: 1, limit: 0, facet_by: facet_by)
          return nil unless result

          return [result, Facets.normalize(result['facet_counts']), Facets.normalize_stats(result['facet_counts'])]
        end

        option_type_ids = grouped.keys
        searches = [
          search_params(query: query, conditions: base + QueryBuilder.grouped_option_conditions(grouped),
                        sort: nil, page: 1, limit: 0, facet_by: facet_by)
        ]
        option_type_ids.each do |option_type_id|
          relaxed = QueryBuilder.grouped_option_conditions(grouped.except(option_type_id))
          searches << search_params(query: query, conditions: base + relaxed,
                                    sort: nil, page: 1, limit: 0, facet_by: 'option_value_ids')
        end

        results = execute_multi_search(searches)
        return nil unless results

        [results.first,
         merge_disjunctive_facets(results.first, results.drop(1), option_type_ids),
         Facets.normalize_stats(results.first['facet_counts'])]
      end

      # Typesense answers multi_search with HTTP 200 even when an individual
      # search failed — the failure is a per-result {error:, code:} body, NOT an
      # exception. Diverges from the single-search path, so check explicitly or
      # a broken filter silently degrades to empty facets.
      def execute_multi_search(searches)
        response = client.multi_search.perform(
          { searches: searches.map { |s| s.merge(collection: collection_name) } }
        )
        results = response['results']

        failed = Array(results).find { |r| r['error'] }
        if failed
          Rails.logger.warn { "[spree_typesense] multi_search failed: #{failed['code']} #{failed['error']}" }
          return nil
        end

        results
      rescue Faraday::ConnectionFailed, Errno::ECONNREFUSED
        raise
      rescue ::Typesense::Error, Faraday::Error => e
        report_search_failure(e, nil)
        nil
      end

      # Start from the main (fully filtered) distribution, then for each option
      # type overwrite the counts of the values BELONGING TO THAT TYPE with the
      # counts from that type's own relaxed query. Values of other types keep
      # the main query's counts. Mapping a value to its type needs the database,
      # same lookup as +group_option_values_by_type+.
      def merge_disjunctive_facets(main_result, relaxed_results, option_type_ids)
        distribution = Facets.normalize(main_result['facet_counts'])
        merged = (distribution['option_value_ids'] || {}).dup

        per_type = {}
        relaxed_results.each_with_index do |result, i|
          per_type[option_type_ids[i]] = Facets.normalize(result['facet_counts'])['option_value_ids'] || {}
        end

        type_of = option_type_of(per_type.values.flat_map(&:keys).uniq)
        per_type.each do |option_type_id, relaxed_distribution|
          relaxed_distribution.each do |prefixed_id, count|
            merged[prefixed_id] = count if type_of[prefixed_id] == option_type_id
          end
        end

        distribution.merge('option_value_ids' => merged)
      end

      # { 'ov_red' => option_type_id, ... } in one query.
      def option_type_of(prefixed_ids)
        raw_ids = prefixed_ids.filter_map { |pid| Spree::OptionValue.decode_prefixed_id(pid) }
        by_raw_id = Spree::OptionValue.where(id: raw_ids).pluck(:id, :option_type_id).to_h

        prefixed_ids.each_with_object({}) do |prefixed_id, acc|
          raw_id = Spree::OptionValue.decode_prefixed_id(prefixed_id)
          acc[prefixed_id] = by_raw_id[raw_id] if raw_id
        end
      end

      # Returns [base_conditions, grouped_option_values]. Kept separate because
      # disjunctive faceting has to rebuild the option half per query while the
      # base half (system scoping + user filters) stays fixed.
      def build_conditions(filters)
        f = filters.respond_to?(:to_unsafe_h) ? filters.to_unsafe_h : (filters || {}).to_h
        f = f.transform_keys(&:to_s)
        option_ids = f.delete('with_option_value_ids')

        base = QueryBuilder.system_conditions(store: store, locale: locale, currency: currency)
        base += QueryBuilder.user_conditions(f)

        [base, group_option_values_by_type(Array(option_ids))]
      end

      def search_params(query:, conditions:, sort:, page:, limit:, facet_by: nil)
        params = {
          q: query.presence || '*',
          query_by: Schema::SEARCHABLE_FIELDS.join(','),
          filter_by: conditions.join(' && '),
          page: page,
          per_page: limit
        }
        params[:sort_by] = QueryBuilder.sort_by(sort) if QueryBuilder.sort_by(sort)
        if facet_by
          params[:facet_by] = facet_by
          # Typesense caps facet values at 10 per field by default and truncates
          # SILENTLY. The price range no longer depends on this (it reads
          # stats.min/max, which are exact at any cardinality), but option and
          # category facets DO — their counts only exist as returned values, and
          # string facets get no stats block. Meilisearch's equivalent default is
          # 100; match it. Residual risk: an option type with >100 values still
          # loses its tail. See the Task 6b report.
          params[:max_facet_values] = MAX_FACET_VALUES
        end
        params
      end

      # NOTE: the rescues above name +::Typesense::Error+, the gem's base class.
      # There is no +Typesense::Error::Error+ — naming it made the rescue clause
      # itself raise NameError, so every API failure escaped as a 500 instead of
      # degrading. Ruby only resolves a rescue's constant when an exception is
      # actually raised, which is why it stayed invisible.
      def report_search_failure(error, query)
        Rails.logger.warn { "[spree_typesense] search failed: #{error.class}: #{error.message}. Run `rake spree:search:reindex`." }
        Rails.error.report(error, handled: true, context: { collection: collection_name, query: query })
      end

      # Typesense has no in-place "alter collection" API — ensure_index_settings!
      # hitting ObjectAlreadyExists means a schema change in Schema.definition
      # will NOT reach an already-created collection. Do not auto-drop it here:
      # that would destroy a live production index. Log loudly instead, with
      # a field-level diff when it can be computed cheaply, so an operator
      # sees WHY new/renamed fields aren't queryable rather than discovering
      # it via a silent no-op.
      def log_schema_drift_warning
        live = client.collections[collection_name].retrieve['fields'].map { |f| f['name'] }
        expected = Schema.definition(collection_name)[:fields].map { |f| f[:name].to_s }
        missing = expected - live
        extra = live - expected

        if missing.any? || extra.any?
          Rails.logger.warn do
            "[spree_typesense] collection '#{collection_name}' already exists with a schema that differs from " \
            "Schema.definition (missing: #{missing.presence || 'none'}; extra: #{extra.presence || 'none'}). " \
            'ensure_index_settings! is a no-op against an existing collection — schema changes require ' \
            'recreating the collection (drop + reindex).'
          end
        else
          Rails.logger.warn do
            "[spree_typesense] collection '#{collection_name}' already exists; ensure_index_settings! is a " \
            'no-op. If Schema.definition changed, recreate the collection and reindex.'
          end
        end
      rescue StandardError => e
        Rails.logger.warn do
          "[spree_typesense] collection '#{collection_name}' already exists; ensure_index_settings! is a " \
          "no-op (schema comparison failed: #{e.class}: #{e.message}). If Schema.definition changed, recreate " \
          'the collection and reindex.'
        end
      end

      # Mirrors meilisearch.rb#group_option_values_by_type. Hits the DB.
      def group_option_values_by_type(prefixed_ids)
        ids = prefixed_ids.flatten.compact.select { |id| QueryBuilder.valid_id?(id) }
        return {} if ids.empty?

        raw = ids.filter_map { |id| Spree::OptionValue.decode_prefixed_id(id) }
        Spree::OptionValue.where(id: raw).group_by(&:option_type_id)
                          .transform_values { |ovs| ovs.map(&:prefixed_id) }
      end

      # The presenter emits Spree's canonical document; Typesense needs fields
      # Spree does not provide. Derive them here rather than forking the presenter.
      def derive_fields(document)
        doc = document.transform_keys(&:to_s)
        raw = doc['available_on']
        doc['available_on_i'] = raw.present? ? Time.parse(raw.to_s).to_i : 0
        doc
      rescue ArgumentError
        doc['available_on_i'] = 0
        doc
      end

      def empty_result(scope, page, limit)
        SearchResult.new(products: scope.none, total_count: 0, pagy: build_pagy(0, page, limit))
      end

      def empty_filters_result
        FiltersResult.new(
          filters: [],
          sort_options: sort_options_payload,
          default_sort: DEFAULT_SORT,
          total_count: 0
        )
      end

      def build_pagy(count, page, limit)
        Pagy::Offset.new(count: count, page: page, limit: limit)
      end

      # On 6.x the Database provider takes the same `audience:` as this one, and
      # uses it for its query and ransack authorisation, so a back-office search
      # (audience: nil) must not degrade into a storefront one. 5.x providers
      # take the store only.
      def fallback_provider
        if SpreeTypesense.spree_6?
          Spree::SearchProvider::Database.new(store, audience: audience)
        else
          Spree::SearchProvider::Database.new(store)
        end
      end

      # The gem's own presenter on every version, unless the application named
      # one. 6.0 core configures none (`search_product_presenter: nil`), and on
      # 5.x core's default would tie the documents to whichever presenter core
      # shipped. `overridden?` tells an application's choice apart from core's
      # default without referencing core's 5.x presenter constant, which on 6.0
      # goes through a deprecation shim. On 6.x the engine registers ours, which
      # also counts as overridden and resolves to the same class.
      def presenter_class
        if Spree::Dependencies.overridden?(:search_product_presenter)
          Spree::Dependencies.search_product_presenter_class
        else
          SpreeTypesense::ProductPresenter
        end
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
