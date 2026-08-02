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
