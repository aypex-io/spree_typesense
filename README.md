# spree_typesense

Typesense search provider for Spree 5.5.

See `tongkat-fitness/docs/specs/typesense-search-provider.md`.

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
