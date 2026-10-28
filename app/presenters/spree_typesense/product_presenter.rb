module SpreeTypesense
  # Builds the Typesense documents for a product: flat, one per
  # (market × locale) the product is priced in.
  #
  # Ported from spree_core 5.6.1's Spree::SearchProvider::ProductPresenter,
  # which Spree 6.0 removed from core (`search_product_presenter: nil`). The
  # gem indexes with this class on every version so the documents no longer
  # depend on whether core happens to ship a presenter.
  #
  # On 5.x the output must equal core's presenter for the same product, field
  # for field; spec/product_presenter_spec.rb compares the two directly. Core's
  # document grew between 5.x releases, so this class reproduces each:
  #   - 5.5.x  no `preorder`, no `cf_*` keys
  #   - 5.6.0  adds `preorder`
  #   - 5.6.1  adds `cf_*` from searchable/sortable metafields
  # On 6.0 the same fields come from 6.0's sources, as in spree_meilisearch
  # 6.0's presenter: categories, `label`, storefront-visible custom fields and a
  # plain-text description. Those sources sit behind the private seams below.
  #
  # Left out on purpose (later work): membership documents for manual sort,
  # `collection_ids` and `option_value_combination_ids`.
  class ProductPresenter
    PREORDER_SINCE = Gem::Version.new('5.6.0')
    METAFIELDS_SINCE = Gem::Version.new('5.6.1')

    attr_reader :product, :store

    def initialize(product, store)
      @product = product
      @store = store
    end

    # Returns an array of documents — one per market × locale combination.
    # Each document has flat name, description, price fields (no dynamic suffixes).
    def call
      documents = []

      market_locale_pairs.each do |market, locale|
        # Skip if product has no price in this currency
        next unless lowest_price(market.currency)

        Mobility.with_locale(locale) do
          documents << build_document(locale, market.currency, default_locale)
        end
      end

      # Fallback for stores without markets (legacy/test)
      if documents.empty?
        fallback_currency = store.default_market&.currency || store.supported_currencies_list.first&.iso_code
        if fallback_currency && lowest_price(fallback_currency)
          documents << build_document(default_locale, fallback_currency, default_locale)
        end
      end

      documents
    end

    private

    # Key order follows core's 5.6.1 presenter, so documents compare equal
    # field by field and serialise identically.
    def build_document(locale, currency, fallback_locale)
      document = {
        # Composite ID: product + locale + currency
        id: "#{product.prefixed_id}_#{locale}_#{currency}",
        product_id: product.prefixed_id,
        locale: locale.to_s,
        currency: currency,
        # Translated fields — with fallback to default locale
        name: translated(product, :name, fallback_locale),
        description: description_text(translated(product, :description, fallback_locale)),
        slug: translated(product, :slug, fallback_locale),
        # Price in this currency
        price: lowest_price(currency)&.to_f,
        compare_at_price: compare_at_price(currency)&.to_f,
        # Non-locale/currency fields
        status: product.status,
        sku: product.sku,
        in_stock: product.in_stock?
      }
      # True when the product has an active pre-order variant, so a scheduled
      # (future-published) launch still surfaces in search. Core added it in
      # 5.6.0; 5.5.x products have no `preorder?`.
      document[:preorder] = product.preorder? if emits_preorder?
      document.merge!(
        store_ids: Array(product.store_id).map(&:to_s),
        channel_ids: channel_ids_for_store,
        discontinue_on: product.discontinue_on&.to_i || 0,
        category_ids: category_ids_with_ancestors,
        category_names: product_categories.map { |c| translated(c, :name, fallback_locale) },
        option_type_ids: product.option_types.map(&:prefixed_id),
        option_type_names: product.option_types.map { |ot| translated(ot, label_attribute, fallback_locale) },
        option_value_ids: variant_option_value_ids,
        option_values: variant_option_values_data.map { |ov| translated(ov, label_attribute, fallback_locale) }.uniq,
        tags: product.tag_list || [],
        units_sold_count: product.units_sold_count || 0,
        available_on: product.available_on&.iso8601,
        created_at: product.created_at&.iso8601,
        updated_at: product.updated_at&.iso8601
      )
      document.merge(custom_field_document_attributes)
    end

    def emits_preorder?
      SpreeTypesense.spree_version >= PREORDER_SINCE
    end

    # --- 5.x / 6.0 source seams -------------------------------------------

    # 6.0 renamed taxons to categories; `Product#taxons` still answers there,
    # but warns. Category prefixed ids become `ctg_` with it.
    def product_categories
      SpreeTypesense.spree_6? ? product.categories : product.taxons
    end

    # 6.0 renamed option type and option value `presentation` to `label`.
    def label_attribute
      SpreeTypesense.spree_6? ? :label : :presentation
    end

    # 6.0 stores descriptions as rich-text HTML in a plain column. Index them
    # as plain text, as spree_meilisearch 6.0 does, so tag names do not become
    # searchable tokens. 5.x documents carry the raw value, as core's did.
    def description_text(description)
      SpreeTypesense.spree_6? ? Spree::RichTextHelper.to_plain_text(description) : description
    end

    # 6.0 deprecates `variants_including_master` in favour of `variants`.
    def option_value_variants
      SpreeTypesense.spree_6? ? product.variants : product.variants_including_master
    end

    # Flat cf_* hash for searchable ∪ sortable custom fields (Meilisearch docs).
    # 6.0: custom fields, storefront-visible ones only — the index is the
    # storefront's, and a value the serializer withholds has no business in a
    # document it can search. 5.6.1: metafields, as core emitted them. Earlier
    # 5.x emitted none.
    def custom_field_document_attributes
      @custom_field_document_attributes ||=
        if SpreeTypesense.spree_6?
          product.custom_fields.filter_map do |custom_field|
            definition = custom_field.custom_field_definition
            next unless definition&.storefront_visible? && (definition.searchable? || definition.sortable?)

            [definition.filter_key, custom_field_index_value(custom_field, definition.field_type)]
          end.to_h
        elsif SpreeTypesense.spree_version >= METAFIELDS_SINCE
          product.metafields.filter_map do |metafield|
            definition = metafield.metafield_definition
            next unless definition&.searchable? || definition&.sortable?

            [definition.filter_key, custom_field_index_value(metafield, definition.field_type)]
          end.to_h
        else
          {}
        end
    end

    # ----------------------------------------------------------------------

    def custom_field_index_value(field, field_type)
      serialized = field.serialize_value
      case field_type
      when 'number'
        serialized.to_f
      else
        serialized.to_s
      end
    end

    # Returns all market × locale pairs for this store
    def market_locale_pairs
      @market_locale_pairs ||= store.markets.flat_map do |market|
        market.supported_locales_list.map { |locale| [market, locale] }
      end
    end

    def default_locale
      @default_locale ||= store.default_market&.default_locale || I18n.default_locale.to_s
    end

    # Read a translated attribute with fallback to default locale.
    def translated(record, attribute, fallback_locale)
      value = record.send(attribute)
      return value if value.present?

      record.send(attribute, locale: fallback_locale.to_sym)
    rescue ArgumentError
      value
    end

    def lowest_price(currency)
      @prices_cache ||= {}
      @prices_cache[currency] = product.price_in(currency)&.amount unless @prices_cache.key?(currency)
      @prices_cache[currency]
    end

    def compare_at_price(currency)
      @compare_at_cache ||= {}
      @compare_at_cache[currency] = product.compare_at_amount_in(currency) unless @compare_at_cache.key?(currency)
      @compare_at_cache[currency]
    end

    def channel_ids_for_store
      @channel_ids_for_store ||= product.product_publications
                                        .joins(:channel)
                                        .where(spree_channels: { store_id: store.id })
                                        .pluck(:channel_id)
                                        .map(&:to_s)
    end

    def category_ids_with_ancestors
      @category_ids_with_ancestors ||= product_categories.flat_map { |c|
        c.self_and_ancestors.map(&:prefixed_id)
      }.uniq
    end

    def variant_option_value_ids
      variant_option_values_data.map(&:prefixed_id).uniq
    end

    def variant_option_values_data
      @variant_option_values_data ||= option_value_variants.flat_map(&:option_values).uniq
    end
  end
end
