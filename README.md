# spree_typesense

A [Typesense](https://typesense.org) search provider for [Spree Commerce](https://spreecommerce.org),
supporting Spree 5.5 to 6.x (`spree_core >= 5.5, < 7.0`).

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

Requires `TYPESENSE_URL` and `TYPESENSE_API_KEY`.

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
- **`Spree::Taxon` became `Spree::Category`**, with `ctg_` prefixed ids.
  `category_ids` and `category_names` come from `product.categories`, and the
  category facet looks up `Spree::Category`. `Spree::Taxon` is a deprecated
  alias on 6.0 and the gem never references it there.
- **Option type and value `presentation` became `label`.**
  `option_type_names` and `option_values` read `label`.
- **Metafields became custom fields.** `cf_*` keys come from
  `product.custom_fields`: definitions that are storefront-visible and marked
  searchable or sortable. As on 5.6.1 they are stored unindexed, so neither
  flag makes them searchable or sortable in Typesense.
- **Products belong to collections, and `in_collection` is a whitelisted
  filter.** Documents carry `collection_ids` (6.x only), and `in_collection`
  filters on it, so a collection listing returns, counts and facets only that
  collection. Manual (position) sort within a collection is not supported.
- **Descriptions are rich-text HTML in a plain column.** `description` is
  indexed as plain text (`Spree::RichTextHelper.to_plain_text`), as
  `spree_meilisearch` 6.0 does, so tag names are not searchable.
- **`variants_including_master` is deprecated.** Option values come from
  `product.variants`.
- **Providers take an `audience:`** (`:store` by default, `nil` for the back
  office). The gem inherits `Base#initialize`, so `custom_field_schema` is
  limited to what that audience may see. When Typesense is unreachable, the
  Database fallback is built with the same audience, so a back-office search
  does not degrade into a storefront one.

Upgrading a store from 5.x to 6.0 changes its category ids (to `ctg_`) and its
option names (to `label`), and adds `collection_ids`, so **reindex after
upgrading Spree** (`rake spree:search:reindex`). `ensure_index_settings!` never
alters an existing collection, so one created before this release has no
`collection_ids` field, and `in_collection` searches against it return nothing
(the failure is logged): drop the collection before reindexing. Staying on 5.x
needs no reindex. Loading and using the gem on 6.0 triggers no Spree
deprecation warning; the suite raises on any.

## Local development

Tests run against a real Typesense server — nothing is mocked. Start one locally
before running the suite:

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
