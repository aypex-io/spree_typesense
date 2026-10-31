# Changelog

## 0.2.0 (unreleased)

### Spree 6.0 support

- Supports Spree 5.5 to 6.0 (`spree_core >= 5.5, < 6.1`; 0.1.x allowed
  `< 6.0`).
- Ships its own product presenter, `SpreeTypesense::ProductPresenter`, and
  indexes with it on every Spree version: Spree 6.0 core ships none. On 5.x
  its documents are the same as core's, field for field. On 6.0 the engine
  registers it as `Spree::Dependencies.search_product_presenter` when
  Typesense is the selected search provider and nothing else is registered.
- Follows Spree 6.0's renames (categories, option `label`, custom fields,
  plain-text descriptions, `variants`) without triggering its deprecations.
- `in_collection` filters on a new `collection_ids` field (Spree 6), so a
  collection listing returns, counts and facets only that collection.
  Existing collections gain the field in place on the next reindex.

### Fixes

- **Reindexing adds new fields in place.** `rake spree:search:reindex` now
  adds any field a release declares that the existing collection lacks,
  without dropping it, so searches keep answering. Before, an existing
  collection was left as it was, and `in_collection` filters against it
  failed. A field whose type changed is reported by name, with the remedy
  (drop and reindex).
- **Rejected documents are reported.** Typesense reports a rejected document
  in its import response rather than as an error, and these used to pass
  unnoticed. Each is now logged with its id and the reason; indexing a
  product raises, so the index job retries; and the reindex carries on, does
  not count them, and fails at the end naming them.
- **Stale documents are removed.** Re-indexing a product deletes the
  documents it no longer produces, such as those of a currency or locale it
  lost, so it stops showing in that market. A product that produces no
  documents loses them all.
- **Pre-orders show.** A product scheduled to publish later is listed while
  it is on pre-order, as Spree's own storefront listing does.
- **Results follow the current channel.** With a current channel, searches
  and facets count only the products published on it, so totals and pages
  match what the channel sells.
- **Default and manual sort.** The filters endpoint offers `manual`, and on a
  Spree 6 collection page reports the collection's own sort order as the
  default. On Spree 6, a category or collection listing in manual order with
  no text query is answered by the `Database` provider, which orders it by
  position.
- **Filtering by two or more option types is exact** on Spree 6: only
  products with one variant matching every selected type are listed.
- **Any Typesense failure falls back to the `Database` provider.** Before,
  only a refused connection did: a timeout, a 5xx, a rejected query (such as
  a filter on a field the collection lacks) or a missing collection returned
  an empty page or empty facets, and an unset `TYPESENSE_URL` or
  `TYPESENSE_API_KEY` raised a 500. Searches and facets now answer from the
  `Database` provider in all these cases, with the failure logged (missing
  configuration once per process) and reported through `Rails.error`.
- **Searches give up sooner on a hung node.** They use their own client with
  a 2 second timeout and no retry, rather than about 10 seconds; set
  `TYPESENSE_SEARCH_TIMEOUT` to change it. Indexing keeps its 5 second timeout
  and one retry.

### Known limitations

See [Known limitations](README.md#known-limitations) in the README:

- Manual (position) order comes from the `Database` provider, on Spree 6
  only; the index carries no positions.
- A full reindex does not remove documents of deleted products.
- Facet counts don't apply narrowing made only to the product scope, such as
  Spree 6's buyer catalogs.
- `price_between`, `in_taxon`, `search_by_name`, other ransack predicates and
  `cf_*` filters are ignored, and `cf_*` sorts are neither offered nor
  applied.

### Upgrading

1. Bump the gem and run `bin/rake spree:search:reindex`. It adds
   `collection_ids` to a collection a 0.1.x release created, in place. A
   store on Spree 5.6 can do this before moving to Spree 6.
2. When moving to Spree 6.0: upgrade Spree, run
   `bin/rake spree:migrate_taxons_to_categories_and_collections`, then
   `bin/rake spree:search:reindex` straight after.
3. `rake spree:search:reindex` now fails, naming the documents, if Typesense
   rejects any of them.

See [Upgrading](README.md#upgrading) for the details, including what to do
when a field's type changes.

## 0.1.2 (2026-08-02)

- Sort options carry `label: nil`, which Spree 5.6's filters serializer
  requires; the filters endpoint no longer fails on Spree 5.6.
