module Spree
  module SearchProvider
    class Typesense < Base
      # Typesense rejected some documents of an import, which it reports per
      # document rather than as an HTTP error.
      class ImportError < StandardError
        # The message names this many ids; #failures keeps them all.
        MAX_IDS_IN_MESSAGE = 50

        # @return [Array<Hash>] `{ id:, error: }` per rejected document
        attr_reader :failures

        # @param collection_name [String]
        # @param failures [Array<Hash>] `{ id:, error: }` per rejected document
        def initialize(collection_name, failures)
          @failures = failures
          ids = failures.map { |f| f[:id] }
          shown = ids.first(MAX_IDS_IN_MESSAGE).join(', ')
          more = ids.size > MAX_IDS_IN_MESSAGE ? " and #{ids.size - MAX_IDS_IN_MESSAGE} more" : ''
          super("#{ids.size} #{ids.size == 1 ? 'document' : 'documents'} rejected by Typesense " \
                "collection '#{collection_name}': #{shown}#{more}")
        end
      end

      # A search Typesense answered with an error body instead of an HTTP
      # error, as multi_search does per search.
      class SearchError < ::Typesense::Error; end

      # What the Typesense client raises when it cannot answer: its own errors
      # (HTTP 4xx/5xx, timeouts, missing configuration, SearchError) and the
      # network errors it gives up on after its retries. The public search
      # entry points answer from the Database provider on any of these. The
      # base class is ::Typesense::Error; there is no ::Typesense::Error::Error.
      UNAVAILABLE_ERRORS = [::Typesense::Error, Faraday::Error, SystemCallError, JSON::ParserError].freeze

      # Set once missing configuration has been logged; see #report_unavailable.
      UNCONFIGURED_LOGGED = Concurrent::AtomicBoolean.new(false)

      # 'manual' is the merchant's own order, as the Database provider offers
      # it (Taxon/Collection::SORT_ORDERS). On Spree 6 a manually sorted
      # category or collection listing is served by the Database provider; see
      # #manual_sort_listing?.
      AVAILABLE_SORT_OPTIONS = %w[manual price -price name -name -available_on available_on best_selling].freeze

      # Spree 5.6's Spree::Api::V3::ProductFilterSortOptionSerializer declares
      # `attributes :id, :label` and raises KeyError when :label is absent.
      # Spree 5.5 only read :id, so the extra key is harmless there — this one
      # shape satisfies both, and 6.0 reads the same keys, which the gemspec
      # range (>= 5.5, < 6.1) requires.
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

      # See #schema_client.
      SCHEMA_CHANGE_TIMEOUT_SECONDS = 120

      # See #search_client. TYPESENSE_SEARCH_TIMEOUT overrides it.
      SEARCH_TIMEOUT_SECONDS = 2

      def self.indexing_required?
        true
      end

      # Creates the collection, or brings an existing one up to
      # Schema.definition. Called by #reindex, so the plain
      # `rake spree:search:reindex` an upgrade runs is enough to add the
      # fields a newer release declares.
      def ensure_index_settings!
        client.collections.create(Schema.definition(collection_name))
      rescue ::Typesense::Error::ObjectAlreadyExists
        update_collection_schema!
        nil
      end

      # Mirrors meilisearch.rb#reindex: default scope is store.products (not
      # Spree::Product.where(store_id:)), batch size 500, deterministic order,
      # lazy-preloaded associations. Returns the number of DOCUMENTS indexed
      # (not products — one product can emit N locale x currency documents).
      #
      # A batch with rejected documents does not stop the reindex, and those
      # documents are not counted. Once every batch is sent, an ImportError
      # names them all, so `rake spree:search:reindex` fails visibly.
      #
      # Documents of products deleted since the last reindex are not removed
      # here: Spree's removal job deletes them as products are destroyed.
      def reindex(scope = nil)
        scope ||= store.products
        ensure_index_settings!

        indexed = 0
        failures = []
        scope.reorder(id: :asc).preload_associations_lazily.find_in_batches(batch_size: 500) do |batch|
          documents = batch.flat_map { |product| presenter_class.new(product, store).call }
          next if documents.empty?

          accepted = documents.size
          begin
            index_batch(documents)
          rescue ImportError => e
            failures.concat(e.failures)
            accepted -= e.failures.size
          end
          indexed += accepted
          Rails.logger.info { "[spree_typesense] indexed #{accepted} (#{indexed} total) into #{collection_name}" }
        end

        Rails.logger.info do
          "[spree_typesense] reindex complete: #{indexed} documents indexed, #{failures.size} failed"
        end
        raise ImportError.new(collection_name, failures) if failures.any?

        indexed
      end

      # Upserts the product's documents, then deletes those of its documents
      # it no longer produces: one product is a document per locale x currency,
      # and a product that lost a currency's price, say, must not stay
      # searchable in that market. A product that produces none loses them all.
      #
      # Raises ImportError (after the deletion) when Typesense rejects a
      # document, so the index job retries it.
      def index(product)
        documents = Array(presenter_class.new(product, store).call)

        rejected = nil
        begin
          results = index_batch(documents)
        rescue ImportError => e
          rejected = e
        end

        remove_stale_documents(product.prefixed_id, documents)
        raise rejected if rejected

        results
      end

      # Typesense answers an import with HTTP 200 and one result per document,
      # in order, so a rejected document raises nothing by itself. Each
      # rejection is logged with its document id, and once the whole batch is
      # sent an ImportError names them all.
      #
      # @return [Array<Hash>, nil] Typesense's per-document results
      # @raise [ImportError] when Typesense rejected any document
      def index_batch(documents)
        return if documents.blank?

        documents = documents.map { |d| derive_fields(d) }
        results = client.collections[collection_name].documents.import(documents, action: 'upsert')

        failures = import_failures(documents, results)
        raise ImportError.new(collection_name, failures) if failures.any?

        results
      end

      def remove(product)
        remove_by_id(product.prefixed_id)
      end

      # Public entry point. Answers from Typesense, or from the Database
      # provider when Typesense cannot answer: unreachable, timed out, a 5xx,
      # a rejected query (a 400 from a field the collection lacks, a missing
      # collection), or not configured. Correct results, more slowly, beat
      # an empty page. Errors that are not Typesense failing still raise.
      def search_and_filter(scope:, query: nil, filters: {}, sort: nil, page: 1, limit: 25)
        if manual_sort_listing?(query: query, filters: filters, sort: sort)
          return fallback_provider.search_and_filter(
            scope: scope, query: query, filters: filters, sort: sort, page: page, limit: limit
          )
        end

        search_with_typesense(scope: scope, query: query, filters: filters, sort: sort, page: page, limit: limit)
      rescue *UNAVAILABLE_ERRORS => e
        report_unavailable(e, query)
        fallback_provider.search_and_filter(
          scope: scope, query: query, filters: filters, sort: sort, page: page, limit: limit
        )
      end

      # Raises when Typesense cannot answer; #search_and_filter falls back.
      def search_with_typesense(scope:, query: nil, filters: {}, sort: nil, page: 1, limit: 25)
        page  = [page.to_i, 1].max
        limit = limit.to_i.clamp(1, 100)

        base, grouped = build_conditions(filters)
        result = execute_search(query: query, conditions: base + QueryBuilder.grouped_option_conditions(grouped),
                                sort: sort, page: page, limit: limit)

        product_ids = result['hits'].map { |h| h['document']['product_id'] }.uniq
        raw_ids = product_ids.filter_map { |pid| Spree::Product.decode_prefixed_id(pid) }

        # Values of two or more option types must sit on ONE variant, as core's
        # `Product.with_option_value_ids` decides on Spree 6. The index holds a
        # product's values as one set, so it only pre-filters; core's scope
        # gives the exact answer, as in Spree's Meilisearch provider. (On 5.x
        # core asks it of the product, as the index does, so this agrees.) A
        # page can then come back short of `limit`, and the total over-counts.
        scope = scope.with_option_value_ids(grouped.values.flatten) if grouped.size > 1

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

      # Facets from Typesense, or, when Typesense cannot answer, from the
      # Database provider, which computes the same ones from the database.
      def filters(scope:, query: nil, filters: {})
        result, distribution, stats = execute_faceted_search(query: query, filters: filters)

        FiltersResult.new(
          filters: Facets.build(distribution, currency: currency, stats: stats),
          sort_options: sort_options_payload,
          default_sort: default_sort_for(filters),
          total_count: result['found'] || 0
        )
      rescue *UNAVAILABLE_ERRORS => e
        report_unavailable(e, query)
        fallback_provider.filters(scope: scope, query: query, filters: filters)
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

      # The client indexing and removal go through: background jobs, which can
      # afford to wait, and retry once on a node that fails.
      def client
        @client ||= build_client(connection_timeout_seconds: 5)
      end

      # The client searches and facets go through. A shopper waits on these,
      # so a hung node must not hold the request: a short timeout and no retry
      # (the indexing client's 5s and one retry cost about 10s), after which
      # the search is answered by the Database provider. The timeout is
      # TYPESENSE_SEARCH_TIMEOUT seconds when that is a positive number.
      def search_client
        @search_client ||= build_client(connection_timeout_seconds: search_timeout_seconds, num_retries: 0)
      end

      def collection_name
        @collection_name ||= "products_#{store.code}"
      end

      private

      # The rejected documents of an import, logged one by one. A result names
      # its document only when the import asked for that, so fall back to the
      # position: Typesense answers one result per document, in order.
      def import_failures(documents, results)
        Array(results).each_with_index.filter_map do |result, index|
          next if result['success']

          failure = { id: result['id'] || documents.dig(index, 'id'), error: result['error'] }
          Rails.logger.error do
            "[spree_typesense] Typesense rejected document #{failure[:id]} in collection " \
            "'#{collection_name}': #{failure[:error]}"
          end
          failure
        end
      end

      # Deletes the product's documents other than `documents`; all of them
      # when `documents` is empty. Ids go into the filter quoted in backticks,
      # Typesense's string literal, because locales such as `en-US` put a
      # hyphen in them. An id that itself holds a backtick cannot be quoted, so
      # nothing is deleted then rather than risk deleting the wrong documents.
      def remove_stale_documents(prefixed_id, documents)
        kept_ids = documents.map { |d| (d[:id] || d['id']).to_s }
        return remove_by_id(prefixed_id) if kept_ids.empty?

        if kept_ids.any? { |id| id.include?('`') }
          Rails.logger.warn { "[spree_typesense] not removing stale documents of #{prefixed_id}: an id holds a backtick" }
          return
        end

        client.collections[collection_name].documents.delete(
          filter_by: "product_id:=#{sanitize_prefixed_id(prefixed_id)} && " \
                     "id:!=[#{kept_ids.map { |id| "`#{id}`" }.join(',')}]"
        )
      rescue ::Typesense::Error::ObjectNotFound
        nil
      end

      # Raises when Typesense cannot answer; the public entry points fall back.
      def execute_search(query:, conditions:, sort:, page:, limit:, facet_by: nil)
        search_client.collections[collection_name].documents.search(
          search_params(query: query, conditions: conditions, sort: sort, page: page, limit: limit, facet_by: facet_by)
        )
      end

      # Faceted read path. Returns [main_result, distribution, stats], and
      # raises when Typesense cannot answer.
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
          result = execute_search(query: query, conditions: base, sort: nil, page: 1, limit: 0, facet_by: facet_by)
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
        [results.first,
         merge_disjunctive_facets(results.first, results.drop(1), option_type_ids),
         Facets.normalize_stats(results.first['facet_counts'])]
      end

      # Typesense answers multi_search with HTTP 200 even when an individual
      # search failed — the failure is a per-result {error:, code:} body, NOT an
      # exception. Diverges from the single-search path, so raise it here as
      # one, or a broken filter would silently serve the wrong facet counts.
      def execute_multi_search(searches)
        response = search_client.multi_search.perform(
          { searches: searches.map { |s| s.merge(collection: collection_name) } }
        )
        results = response['results']

        failed = Array(results).find { |r| r['error'] }
        raise SearchError, "multi_search failed: #{failed['code']} #{failed['error']}" if failed

        results
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
        f = normalize_filters(filters)
        option_ids = f.delete('with_option_value_ids')

        base = QueryBuilder.system_conditions(store: store, locale: locale, currency: currency,
                                              channel_id: current_channel&.id)
        base += QueryBuilder.user_conditions(f)

        [base, group_option_values_by_type(Array(option_ids))]
      end

      # The channel the request is served on, read as core's storefront scope
      # and the Meilisearch provider read it on every supported version. Nil
      # outside a channel context, and then nothing is narrowed.
      def current_channel
        Spree::Current.channel
      end

      # A string-keyed copy of the filters, whichever shape they arrive in:
      # Parameters, a symbol- or string-keyed Hash, or nil.
      def normalize_filters(filters)
        f = filters.respond_to?(:to_unsafe_h) ? filters.to_unsafe_h : (filters || {}).to_h
        f.transform_keys(&:to_s)
      end

      # The sort a listing starts on, as Spree 6's FiltersAggregator and
      # Meilisearch provider derive it: the collection's own sort order, given
      # in the API's form ('price desc' -> '-price'), and 'manual' otherwise.
      # Only 6.x's filters endpoint passes `_collection`.
      def default_sort_for(filters)
        collection = normalize_filters(filters)['_collection']
        sort_order = collection.sort_order.presence if collection.respond_to?(:sort_order)
        field, direction = (sort_order || DEFAULT_SORT).to_s.split(' ', 2)
        direction == 'desc' ? "-#{field}" : field
      end

      # Whether this is a single category or collection listing in the
      # merchant's manual order, with no text query. Spree 6's Database
      # provider orders those by position, the sort being 'manual' or omitted
      # there (`manual_sort_grouping`); the index carries no positions, so
      # #search_and_filter hands them to it. A text query keeps relevance, and
      # several categories have no single position to follow.
      #
      # Spree 5's Database provider applies no position order through this
      # API, so on 5.x a listing stays on Typesense.
      def manual_sort_listing?(query:, filters:, sort:)
        return false unless SpreeTypesense.spree_6?
        return false if query.present?
        return false unless sort.blank? || sort.to_s == 'manual'

        f = normalize_filters(filters)
        QueryBuilder.valid_id?(f['in_collection']) || QueryBuilder.valid_id?(f['in_category'])
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

      # Logs and reports a failure the caller is about to answer from the
      # Database provider. Missing configuration is logged and reported once
      # per process: it fails every search the same way until someone sets it.
      def report_unavailable(error, query)
        if error.is_a?(::Typesense::Error::MissingConfiguration)
          return unless UNCONFIGURED_LOGGED.make_true
        end

        Rails.logger.error do
          "[spree_typesense] Typesense could not answer (#{error.class}: #{error.message}); answering from the " \
          'Database provider. If the collection is missing or out of date, run `rake spree:search:reindex`.'
        end
        Rails.error.report(error, handled: true, context: { collection: collection_name, query: query })
      end

      # Typesense alters a live collection in place: PATCH /collections/:name
      # with the fields to add. Documents already stored keep their values and
      # gain the new fields when next indexed, which #reindex does straight
      # after. So a field a release adds reaches an existing collection without
      # dropping it, and a store keeps serving searches throughout.
      #
      # What Typesense cannot do in place is change a field's type. Never drop
      # the collection here, which would empty a live index: name the field and
      # the remedy instead.
      #
      # A failed PATCH raises, so a reindex stops rather than reporting success
      # against a collection that still cannot serve the new filters.
      def update_collection_schema!
        live_fields = client.collections[collection_name].retrieve['fields']

        missing = Schema.missing_fields(live_fields)
        if missing.any?
          schema_client.collections[collection_name].update(fields: missing)
          Rails.logger.info do
            "[spree_typesense] added #{missing.map { |f| f[:name] }.join(', ')} to collection '#{collection_name}'"
          end
        end

        Schema.type_mismatches(live_fields).each do |mismatch|
          Rails.logger.warn do
            "[spree_typesense] collection '#{collection_name}' declares '#{mismatch[:name]}' as " \
            "#{mismatch[:live_type]}, but this release declares it #{mismatch[:type]}. Typesense cannot change " \
            "a field's type in place: drop the collection and reindex (`rake spree:search:reindex`)."
          end
        end
      end

      # Schema changes block writes to the collection until Typesense finishes
      # them, and the response comes only then, so they need a far longer
      # timeout than indexing. No retries: Typesense runs one alter at a time,
      # and would refuse a retry while the first is still running.
      def schema_client
        @schema_client ||= build_client(connection_timeout_seconds: SCHEMA_CHANGE_TIMEOUT_SECONDS, num_retries: 0)
      end

      # Raises Typesense::Error::MissingConfiguration, rather than KeyError,
      # when TYPESENSE_URL or TYPESENSE_API_KEY is unset or the URL does not
      # parse, so a search treats it as Typesense being unavailable.
      def build_client(**options)
        url = ENV.fetch('TYPESENSE_URL', nil).presence
        api_key = ENV.fetch('TYPESENSE_API_KEY', nil).presence
        unless url && api_key
          missing = { 'TYPESENSE_URL' => url, 'TYPESENSE_API_KEY' => api_key }.select { |_, v| v.nil? }.keys
          raise ::Typesense::Error::MissingConfiguration, "#{missing.join(' and ')} not set"
        end

        uri = URI.parse(url)
        ::Typesense::Client.new(
          nodes: [{ host: uri.host, port: uri.port, protocol: uri.scheme }],
          api_key: api_key,
          **options
        )
      rescue URI::InvalidURIError => e
        raise ::Typesense::Error::MissingConfiguration, "TYPESENSE_URL is not a valid URL: #{e.message}"
      end

      def search_timeout_seconds
        configured = Float(ENV.fetch('TYPESENSE_SEARCH_TIMEOUT', nil), exception: false)
        configured&.positive? ? configured : SEARCH_TIMEOUT_SECONDS
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
      # a subclass of it. 6.0 core configures none (`search_product_presenter:
      # nil`), and on 5.x core's default would tie the documents to whichever
      # presenter core shipped. `overridden?` tells an application's choice
      # apart from core's default without referencing core's 5.x presenter
      # constant, which on 6.0 goes through a deprecation shim. On 6.x the
      # engine registers ours, which also counts as overridden.
      #
      # The setting is shared by every installed search gem, so anything that is
      # not ours is ignored: with spree_meilisearch installed it may hold
      # Meilisearch's presenter, whose documents this schema does not describe.
      def presenter_class
        configured = Spree::Dependencies.search_product_presenter_class if Spree::Dependencies.overridden?(:search_product_presenter)
        configured.is_a?(Class) && configured <= SpreeTypesense::ProductPresenter ? configured : SpreeTypesense::ProductPresenter
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
