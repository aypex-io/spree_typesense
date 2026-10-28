module Spree
  module SearchProvider
    class Typesense < Base
      module QueryBuilder
        PREFIXED_ID_PATTERN = /\A[a-z]+_[A-Za-z0-9]+\z/

        SORT_MAP = {
          'price'         => 'price:asc',
          '-price'        => 'price:desc',
          'name'          => 'name:asc',
          '-name'         => 'name:desc',
          'available_on'  => 'available_on:asc',
          '-available_on' => 'available_on:desc',
          'best_selling'  => 'units_sold_count:desc'
        }.freeze

        module_function

        # Always applied. Mirrors meilisearch.rb#system_filter_conditions.
        # locale/currency are NOT optional — documents are composite-keyed per
        # locale x currency, so omitting them returns every market's copy.
        def system_conditions(store:, locale:, currency:, now: Time.current)
          conditions = ["store_ids:=#{store.id.to_i}"]
          conditions << "status:=active"
          conditions << "locale:=#{locale.to_s.gsub(/[^a-zA-Z_-]/, '')}"
          conditions << "currency:=#{currency.to_s.upcase.gsub(/[^A-Z]/, '')}"
          # available_on_i, NOT available_on: Typesense silently matches zero
          # documents for range operators on string fields.
          conditions << "available_on_i:<=#{now.to_i}"
          # 0 is the sentinel for "never discontinued"; a future timestamp
          # means discontinued LATER, so those products must still be
          # visible now. Mirrors meilisearch.rb's
          # "(discontinue_on = 0 OR discontinue_on > now)".
          conditions << "(discontinue_on:=0 || discontinue_on:>#{now.to_i})"
          conditions
        end

        # SECURITY: values here come from Store API query params. Numbers are
        # coerced with to_f; ids are validated AND stripped; anything invalid is
        # DROPPED, never repaired. Matches meilisearch.rb#build_filter_condition.
        def user_conditions(filters)
          f = filters.respond_to?(:to_unsafe_h) ? filters.to_unsafe_h : filters.to_h
          f = f.transform_keys(&:to_s)

          f.filter_map { |key, value| condition_for(key, value) unless value.nil? || value.to_s.empty? }
        end

        def condition_for(key, value)
          case key
          when 'price_gte' then "price:>=#{Array(value).first.to_f}"
          when 'price_lte' then "price:<=#{Array(value).first.to_f}"
          when 'in_stock'  then ('in_stock:=true'  if value.to_s != '0')
          when 'out_of_stock' then ('in_stock:=false' if value.to_s != '0')
          when 'in_category'
            "category_ids:=#{sanitize_id(value)}" if valid_id?(value)
          when 'in_categories'
            ids = valid_ids(value)
            "category_ids:=[#{ids.join(',')}]" if ids.any?
          # Spree 6.0 whitelists in_collection and its Database provider
          # applies it; 5.x has no collections, and documents built there carry
          # no collection_ids. Membership only: manual (position) sort within a
          # collection needs membership documents, which this gem does not emit.
          when 'in_collection'
            "collection_ids:=#{sanitize_id(value)}" if SpreeTypesense.spree_6? && valid_id?(value)
          when 'with_option_value_ids'
            nil # handled by grouped_option_conditions
          end
        end

        # OR within an option type, AND across option types.
        def grouped_option_conditions(grouped)
          grouped.filter_map do |_type_id, prefixed_ids|
            ids = valid_ids(prefixed_ids)
            next if ids.empty?

            ids.length > 1 ? "option_value_ids:=[#{ids.join(',')}]" : "option_value_ids:=#{ids.first}"
          end
        end

        def sort_by(sort_param)
          SORT_MAP[sort_param.to_s]
        end

        def valid_id?(value)  = PREFIXED_ID_PATTERN.match?(value.to_s)
        def sanitize_id(value) = value.to_s.gsub(/[^a-zA-Z0-9_]/, '')
        def valid_ids(values)  = Array(values).filter_map { |v| sanitize_id(v) if valid_id?(v) }
      end
    end
  end
end
