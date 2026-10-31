# spree_typesense

A [Typesense](https://typesense.org) search provider for [Spree Commerce](https://spreecommerce.org),
supporting Spree 5.5 to 6.0 (`spree_core >= 5.5, < 6.1`).

Spree 5.5 ships two search providers — `Database` and `Meilisearch` (which moved
into the `spree_meilisearch` gem in 6.0). This gem adds a Typesense one,
implementing the same `Spree::SearchProvider::Base` contract so
nothing downstream changes: it returns Spree's own `SearchResult` and
`FiltersResult` objects, and Spree's existing indexing jobs and
`rake spree:search:reindex` work unmodified.

Motivation: Meilisearch's open-source build is single-node, with HA reserved for
its Enterprise edition. Typesense ships Raft-based clustering in open source, so
a multi-node cluster survives losing a node.

## Install

```ruby
gem 'spree_typesense', github: 'aypex-io/spree_typesense', tag: 'v0.2.0'
```

Then select the provider by environment:

```ruby
# config/initializers/spree.rb
Spree.search_provider = 'Spree::SearchProvider::Typesense' if ENV['TYPESENSE_URL'].present?
```

Requires `TYPESENSE_URL` and `TYPESENSE_API_KEY`. `TYPESENSE_SEARCH_TIMEOUT`
(seconds, default `2`) is optional; see
[When Typesense is unavailable](#when-typesense-is-unavailable).

Then build the index: `bin/rake spree:search:reindex`.

See [CHANGELOG.md](CHANGELOG.md) for what each release changes.

## When Typesense is unavailable

Searches and filter facets answer from Spree's `Database` provider whenever
Typesense cannot answer: the connection is refused, the request times out,
Typesense returns a 5xx, or it rejects the query (a missing collection, a
filter on a field the collection lacks). On Spree 6 the `Database` provider is
built with the same `audience:`, so a back-office search stays one. Correct
results, more slowly, beat an empty page. Each failure is logged at error level
and reported through `Rails.error` as handled.

An unset `TYPESENSE_URL` or `TYPESENSE_API_KEY` counts as unavailable too:
searches answer from the `Database` provider, and the problem is logged once
per process rather than on every search. Indexing still raises, so the jobs
fail and retry.

Searches and facets go through their own client, with a 2 second timeout and
no retry, so a hung node costs a shopper about 2 seconds before the fallback
answers. Set `TYPESENSE_SEARCH_TIMEOUT` (in seconds, e.g. `1.5`) to change it.
Indexing keeps a 5 second timeout and one retry, and Spree's index jobs retry
on failure.

## Known limitations

- **Manual (position) sort.** The index carries no positions. On Spree 6, a
  single category or collection listing in manual order (`sort` omitted or
  `manual`) with no text query is answered by the `Database` provider, which
  orders it by position. With a text query the order is relevance. On Spree 5,
  whose `Database` provider applies no position order through the Store API,
  `manual` is Typesense's default ranking.
- **A full reindex does not remove documents of deleted products.** It upserts
  every product's documents. Spree's removal job deletes a product's documents
  when the product is destroyed; to clear any left behind, drop the collection
  and reindex (see [Upgrading](#upgrading)).
- **Facets don't apply catalog narrowing.** Facet counts come from the index
  and the filters given, not from the product `scope` the filters endpoint
  passes, so narrowing applied only to that scope is not reflected: Spree 6's
  buyer catalogs, and a `category_id` sent without an `in_category` filter.
  Search results are always intersected with the scope.
- **Some filters and sorts are ignored.** The index answers `price_gte`,
  `price_lte`, `in_stock`, `out_of_stock`, `in_category`, `in_categories`,
  `in_collection` (Spree 6) and `with_option_value_ids`. It ignores
  `price_between`, `in_taxon`, `search_by_name`, other ransack predicates such
  as `name_cont`, and `cf_*` custom-field filters. `cf_*` sorts are neither
  offered nor applied; such a request gets the default ranking.
- **Values of two or more option types** must sit on one variant on Spree 6.
  The index pre-filters by each type, and the product scope is narrowed through
  core's `Product.with_option_value_ids`, so a page can come back shorter than
  `limit` and the total can over-count.

## Engine behaviours this gem depends on

Typesense and Meilisearch diverge in several ways that fail **silently** — no
error, just wrong answers. Those behaviours are pinned as executable specs in
`spec/typesense_behaviour_spec.rb`, which doubles as an upgrade canary: run it
first when bumping the Typesense version.

### Spree versions

The gem builds its documents with its own `SpreeTypesense::ProductPresenter`
on every Spree version, so the index does not depend on which presenter core
happens to ship. On 5.x its documents are exactly those of core's
`Spree::SearchProvider::ProductPresenter` for that release
(`spec/product_presenter_spec.rb` compares the two field for field): 5.5.x
emits no `preorder`, 5.6.0 adds it, and 5.6.1 adds `cf_*` keys for searchable
or sortable metafields. The presenter follows the capabilities core's models
gained in those releases (`Product#preorder?`, the metafield definition's
`searchable?`) rather than the patch version.

An application can set `Spree::Dependencies.search_product_presenter` to a
subclass of `SpreeTypesense::ProductPresenter`, and the provider indexes with
it. Any other presenter there is ignored and the gem's own is used: the
setting is shared by every installed search gem, and another gem's documents
(`spree_meilisearch`'s, say) do not fit this collection's schema.

`cf_*` keys are stored in each document but are not declared in the schema, so
Typesense does not index them: they cannot be searched, filtered or sorted on.
That is the same on 5.6.1 and 6.x.

Spree 6.0 changed what the documents are built from. The gem follows it, and
emits the same fields as on 5.6:

- **Core ships no search presenter** (`search_product_presenter: nil`). At boot
  the engine registers `SpreeTypesense::ProductPresenter` as
  `Spree::Dependencies.search_product_presenter`, unless the application or
  another search gem already set one — the same pattern as `spree_meilisearch`.
  It registers only when Typesense is the selected `Spree.search_provider`, so
  with `spree_meilisearch` installed alongside, each gem's presenter goes with
  its own provider. Either way the provider indexes with this gem's presenter
  (see above).
- **`Spree::Taxon` became `Spree::Category`.** `category_ids` and
  `category_names` come from `product.categories`, and the category facet
  looks up `Spree::Category`. `Spree::Taxon` is a deprecated alias on 6.0 and
  the gem never references it there. The prefixed ids do not change: taxons
  already carried `ctg_` ids on 5.5 and 5.6.
- **Option type and value `presentation` became `label`.**
  `option_type_names` and `option_values` read `label`.
- **Metafields became custom fields.** `cf_*` keys come from
  `product.custom_fields`: definitions that are storefront-visible and marked
  searchable or sortable. As on 5.6.1 they are stored unindexed, so neither
  flag makes them searchable or sortable in Typesense.
- **Products belong to collections, and `in_collection` is a whitelisted
  filter.** Documents carry `collection_ids` (6.x only), and `in_collection`
  filters on it, so a collection listing returns, counts and facets only that
  collection. A listing in manual (position) order is answered by the
  `Database` provider; see [Known limitations](#known-limitations).
- **Descriptions are rich-text HTML in a plain column.** `description` is
  indexed as plain text (`Spree::RichTextHelper.to_plain_text`), as
  `spree_meilisearch` 6.0 does, so tag names are not searchable.
- **`variants_including_master` is deprecated.** Option values come from
  `product.variants`.
- **Providers take an `audience:`** (`:store` by default, `nil` for the back
  office). The gem inherits `Base#initialize`, so `custom_field_schema` is
  limited to what that audience may see. When Typesense cannot answer, the
  Database fallback is built with the same audience, so a back-office search
  does not degrade into a storefront one.

Loading and using the gem on 6.0 triggers no Spree deprecation warning; the
suite raises on any.

## Upgrading

### To this release

Bump the gem, then run `bin/rake spree:search:reindex`. The reindex first
brings the existing collection up to this release's schema: it adds every
field the collection lacks (`collection_ids`, for a collection a 0.1.x release
created) in place, through Typesense's schema update. Nothing is dropped, and
searches keep answering throughout; Typesense holds writes to the collection
until the field is added.

A store on Spree 5.6 can bump and reindex there, ahead of moving to Spree 6:
the collection then already has the field.

The reindex now fails, naming the documents, if Typesense rejects any of them.

### To Spree 6.0

1. Upgrade Spree, run its migrations, then
   `bin/rake spree:migrate_taxons_to_categories_and_collections`.
2. Then run `bin/rake spree:search:reindex`, straight after: documents gain
   `collection_ids` from the migrated collections, and option names from
   `label`. Category ids do not change. If the collection predates this
   release, the same reindex adds the field first.

Until a product is reindexed its documents carry no `collection_ids`, so
collection listings sorted by a field (price, name, ...) miss it in the
meantime. Listings in manual order are answered by the `Database` provider and
are unaffected.

### A field whose type changed

Typesense can add fields in place but cannot change a field's type. If a
release changes one, the reindex logs a warning naming the field; drop the
collection, `products_<store code>`, and reindex:

```bash
curl -X DELETE "$TYPESENSE_URL/collections/products_<store code>" \
  -H "X-TYPESENSE-API-KEY: $TYPESENSE_API_KEY"
bin/rake spree:search:reindex
```

or, from a console,
`Spree::SearchProvider::Typesense.new(store).client.collections["products_#{store.code}"].delete`.

While the collection is gone, searches answer from the `Database` provider.
Once the reindex has recreated it, they answer from Typesense, which holds only
the products indexed so far: search returns nothing at first, and is
incomplete until the reindex finishes. Run it at a quiet time.

## Local development

Tests run against a real Typesense server. The few that check only which
requests the provider sends use a recording client in its place
(`spec/support/recording_typesense_client.rb`); what Typesense does with those
requests is pinned against the server. Start one locally before running the
suite:

```bash
curl -O https://dl.typesense.org/releases/30.2/typesense-server-30.2-darwin-arm64.tar.gz
tar xzf typesense-server-30.2-darwin-arm64.tar.gz
./typesense-server --data-dir=/tmp/ts --api-key=test-key --listen-port=8108
```

The version **must match the pinned CI version (`30.2`, see `.github/workflows/ci.yml`)**
so local and CI behavior agree. Apple's `container` CLI is not required (and, as of
2026-08-02, its `apiserver` does not reliably start on all machines) — the native
binary above is the supported local path.

Then run the suite:

```bash
TYPESENSE_URL=http://localhost:8108 TYPESENSE_API_KEY=test-key bundle exec rspec
```

## Typesense behaviours this gem depends on

`spec/typesense_behaviour_spec.rb` asserts, directly against a live Typesense
server (not through our provider), five behaviours this gem's design leans on.
Each one is a real defect that hid behind a stub during the original build —
this suite is what would have caught it, and now exists so the *next* Typesense
upgrade fails loudly here instead of silently in production.

1. **Range operators on string fields silently match nothing** — no error,
   just zero results. This is why the provider derives an int64
   `available_on_i` at index time instead of filtering on an ISO8601 string.
2. **Facet values are capped at 10 by default and truncated silently** —
   but numeric facets still expose exact `stats.min`/`stats.max` (and those
   stats respect `filter_by`), while non-numeric facets get a stats block
   with no min/max at all. This is the escape hatch the price facet uses
   instead of raising `max_facet_values`.
3. **Zero-count facet values are omitted entirely, not reported as 0** — the
   disjunctive facet merge has to treat a missing value as absent, not zero.
4. **`multi_search` returns per-result `{error, code}` bodies instead of
   raising** — a failing sub-search degrades silently unless each result is
   checked individually.
5. **`::Typesense::Error::Error` does not exist** — the base class is
   `::Typesense::Error`. A `rescue` naming the former is invisible dead code.

**Run this suite first whenever the pinned Typesense version changes.** A
failure here means an assumption above no longer holds — investigate before
assuming the rest of the gem is safe to upgrade.
