require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense::QueryBuilder do
  let(:store) { instance_double('Spree::Store', id: 7) }

  describe '.system_conditions' do
    subject(:conds) do
      described_class.system_conditions(
        store: store, locale: 'en', currency: 'USD',
        now: Time.utc(2026, 8, 2, 12, 0, 0)
      )
    end

    it 'scopes to the store' do
      expect(conds).to include("store_ids:=7")
    end

    # THE multi-market test. Without these two, every market's copy matches.
    it 'scopes to the requested locale and currency' do
      expect(conds).to include('locale:=en', 'currency:=USD')
    end

    it 'restricts to active products' do
      expect(conds).to include('status:=active')
    end

    it 'excludes future-dated products' do
      expect(conds.join(' ')).to include('available_on:<=2026-08-02')
    end

    # 0 is the sentinel for "never discontinued"; a future discontinue_on
    # means the product is discontinued LATER and must still be visible now.
    # This must fail against a bare `discontinue_on:=0` filter.
    it 'keeps products whose discontinue date is in the future' do
      clause = conds.find { |c| c.include?('discontinue_on') }
      expect(clause).to include('discontinue_on:=0')
      expect(clause).to include('||')
      expect(clause).to match(/discontinue_on:>\d+/)
    end

    it 'strips hostile characters out of locale and currency' do
      out = described_class.system_conditions(
        store: store, locale: "en' || x:='y", currency: 'US D||', now: Time.utc(2026, 1, 1)
      )
      # discontinue_on legitimately contains '||', so check the locale/
      # currency clauses specifically rather than the whole joined string.
      locale_and_currency = out.select { |c| c.start_with?('locale:', 'currency:') }.join(' ')
      expect(locale_and_currency).not_to include("'")
      expect(locale_and_currency).not_to include('||')
    end

    it 'upcases lowercase currency codes rather than dropping them' do
      out = described_class.system_conditions(
        store: store, locale: 'en', currency: 'usd', now: Time.utc(2026, 1, 1)
      )
      expect(out).to include('currency:=USD')
    end
  end

  describe '.user_conditions' do
    it 'coerces price bounds to numbers so filter syntax cannot be injected' do
      out = described_class.user_conditions(price_gte: '10 || status:=draft')
      expect(out).to include('price:>=10.0')
      expect(out.join(' ')).not_to include('draft')
    end

    it 'maps in_stock and out_of_stock' do
      expect(described_class.user_conditions(in_stock: '1')).to include('in_stock:=true')
      expect(described_class.user_conditions(out_of_stock: '1')).to include('in_stock:=false')
      expect(described_class.user_conditions(in_stock: '0')).to be_empty
    end

    it 'filters by category using category_ids' do
      expect(described_class.user_conditions(in_category: 'tax_x')).to include('category_ids:=tax_x')
    end

    it 'drops a category id that is not a well-formed prefixed id' do
      out = described_class.user_conditions(in_category: "tax_x || category_ids:=tax_secret")
      expect(out).to be_empty
    end

    it 'ORs multiple categories together' do
      out = described_class.user_conditions(in_categories: %w[tax_a tax_b])
      expect(out.first).to eq('category_ids:=[tax_a,tax_b]')
    end

    it 'ignores with_option_value_ids (handled by grouped conditions)' do
      expect(described_class.user_conditions(with_option_value_ids: %w[ov_a])).to be_empty
    end

    it 'does not raise when a price param arrives as an Array' do
      expect { described_class.user_conditions(price_gte: ['1']) }.not_to raise_error
      out = described_class.user_conditions(price_gte: ['1'])
      expect(out.first).to eq('price:>=1.0')
    end
  end

  describe '.grouped_option_conditions' do
    # OR within an option type, AND across option types — the standard
    # e-commerce faceting semantic.
    it 'ORs within a type and ANDs across types' do
      grouped = { 1 => %w[ov_red ov_blue], 2 => %w[ov_large] }
      out = described_class.grouped_option_conditions(grouped)
      expect(out).to contain_exactly('option_value_ids:=[ov_red,ov_blue]', 'option_value_ids:=ov_large')
    end
  end

  describe '.sort_by' do
    it 'maps the supported sort params' do
      expect(described_class.sort_by('price')).to eq('price:asc')
      expect(described_class.sort_by('-price')).to eq('price:desc')
      expect(described_class.sort_by('name')).to eq('name:asc')
      expect(described_class.sort_by('-available_on')).to eq('available_on:desc')
      expect(described_class.sort_by('best_selling')).to eq('units_sold_count:desc')
    end

    it 'returns nil for blank or unknown sorts so Typesense uses its default' do
      expect(described_class.sort_by(nil)).to be_nil
      expect(described_class.sort_by('nonsense')).to be_nil
    end
  end
end
