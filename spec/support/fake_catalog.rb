# Plain-Ruby stand-ins for the catalogue a product presenter reads: product,
# store, markets, categories, option types and values, variants, publications
# and custom fields. No ActiveRecord, matching the rest of this suite. Each
# fake answers only what a presenter calls, so a presenter that starts calling
# something new fails loudly with NoMethodError instead of passing.
#
# Translated columns take a { 'locale' => value } hash and answer for the
# current Mobility locale, or for `locale:` when given — the two calls the
# presenters' `translated` helper makes.
#
# The 5.x names Spree 6.0 deprecated (#taxons, #variants_including_master,
# #metafields) warn through Spree::Deprecation on 6.x exactly as core does,
# and the suite raises on any deprecation, so a presenter reaching for them on
# 6.x fails.
module FakeCatalog
  module Translated
    private

    def translate(values, locale)
      return values unless values.is_a?(Hash)

      values[(locale || Mobility.locale).to_s]
    end

    def deprecated_on_spree_6(message)
      Spree::Deprecation.warn(message) if SpreeTypesense.spree_6?
    end
  end

  Category = Struct.new(:prefixed_id, :names, :parent, keyword_init: true) do
    include Translated

    def name(locale: nil) = translate(names, locale)
    def self_and_ancestors = [*parent&.self_and_ancestors, self]
  end

  # `presentation` is the 5.x name, `label` the 6.0 one. Fakes carry different
  # values in each so a presenter reading the wrong one is caught.
  OptionType = Struct.new(:prefixed_id, :presentations, :labels, keyword_init: true) do
    include Translated

    def presentation(locale: nil) = translate(presentations, locale)
    def label(locale: nil) = translate(labels, locale)
  end

  OptionValue = Struct.new(:prefixed_id, :presentations, :labels, keyword_init: true) do
    include Translated

    def presentation(locale: nil) = translate(presentations, locale)
    def label(locale: nil) = translate(labels, locale)
  end

  Variant = Struct.new(:option_values, keyword_init: true)

  Price = Struct.new(:amount)

  CustomFieldDefinition = Struct.new(:filter_key, :field_type, :searchable, :sortable, :storefront_visible,
                                     keyword_init: true) do
    def searchable? = !!searchable
    def sortable? = !!sortable
    def storefront_visible? = !!storefront_visible
  end

  # A Spree::Metafield on 5.x, a Spree::CustomField on 6.0.
  CustomField = Struct.new(:definition, :value, keyword_init: true) do
    def custom_field_definition = definition
    def metafield_definition = definition
    def serialize_value = value
  end

  Market = Struct.new(:currency, :supported_locales_list, :default_locale, keyword_init: true)

  Currency = Struct.new(:iso_code)

  Store = Struct.new(:id, :code, :markets, :default_market, :supported_currencies_list, keyword_init: true)

  # product.product_publications.joins(:channel).where(spree_channels: { store_id: }).pluck(:channel_id)
  class Publications
    def initialize(channel_ids_by_store_id)
      @channel_ids_by_store_id = channel_ids_by_store_id
    end

    def joins(_association) = self

    def where(conditions)
      store_id = conditions.fetch(:spree_channels).fetch(:store_id)
      Publications.new(store_id => @channel_ids_by_store_id.fetch(store_id, []))
    end

    def pluck(_column) = @channel_ids_by_store_id.values.flatten
  end

  class Product
    include Translated

    attr_reader :prefixed_id, :status, :sku, :store_id, :discontinue_on, :option_types, :tag_list,
                :units_sold_count, :available_on, :created_at, :updated_at, :product_publications

    def initialize(prefixed_id:, names:, descriptions: nil, slugs: nil, prices: {}, compare_at: {},
                   status: 'active', sku: nil, in_stock: true, preorder: false, store_id: 1,
                   channel_ids_by_store_id: {}, discontinue_on: nil, categories: [], option_types: [],
                   variants: [], master: Variant.new(option_values: []), tag_list: [], units_sold_count: 0,
                   available_on: nil, created_at: nil, updated_at: nil, custom_fields: [])
      @prefixed_id = prefixed_id
      @names = names
      @descriptions = descriptions
      @slugs = slugs
      @prices = prices
      @compare_at = compare_at
      @status = status
      @sku = sku
      @in_stock = in_stock
      @preorder = preorder
      @store_id = store_id
      @product_publications = Publications.new(channel_ids_by_store_id)
      @discontinue_on = discontinue_on
      @categories = categories
      @option_types = option_types
      @variants = variants
      @master = master
      @tag_list = tag_list
      @units_sold_count = units_sold_count
      @available_on = available_on
      @created_at = created_at
      @updated_at = updated_at
      @custom_fields = custom_fields
    end

    def name(locale: nil) = translate(@names, locale)
    def description(locale: nil) = translate(@descriptions, locale)
    def slug(locale: nil) = translate(@slugs, locale)

    def price_in(currency) = @prices.key?(currency) ? Price.new(@prices[currency]) : nil
    def compare_at_amount_in(currency) = @compare_at[currency]

    def in_stock? = @in_stock
    def preorder? = @preorder

    def categories = @categories
    def variants = @variants
    def custom_fields = @custom_fields

    def taxons
      deprecated_on_spree_6('Spree::Product#taxons is deprecated and will be removed in Spree 6.1. Use #categories instead.')
      @categories
    end

    def variants_including_master
      deprecated_on_spree_6('Spree::Product#variants_including_master is deprecated and will be removed in Spree 6.1. Use #variants instead.')
      [@master, *@variants]
    end

    def metafields
      deprecated_on_spree_6('Spree::Product#metafields is deprecated. Use #custom_fields instead.')
      @custom_fields
    end
  end
end
