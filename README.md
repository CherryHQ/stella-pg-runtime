# stella-pg-runtime

Native PostgreSQL runtime bundles for Stella.

This repository builds and publishes per-platform PostgreSQL runtime archives that Stella can download during release builds and embed into the Stella binary.

## Bundle contents

Current target stack:

- macOS: PostgreSQL 18.4 from Postgres.app 2.9.5, pgvector 0.8.2 from Postgres.app, pg_search 0.24.1 from ParadeDB `.pkg`
- Linux deb: PostgreSQL 18.4 and pgvector 0.8.2 from PGDG packages, pg_search 0.24.1 from ParadeDB `.deb`

Published Linux variants target Debian/Ubuntu glibc systems where ParadeDB publishes pg_search `.deb` assets:

- `linux-amd64-bookworm`
- `linux-arm64-bookworm`
- `linux-amd64-noble`
- `linux-arm64-noble`
- `linux-amd64-trixie`
- `linux-arm64-trixie`

Ubuntu `jammy` and `resolute` are intentionally unsupported until ParadeDB publishes matching pg_search `.deb` assets.

Bundle layout:

```text
postgres/
  bin/
  lib/
  share/
extensions/
  lib/
  share/extension/
LICENSES/
manifest.json
```

## Why this repo exists

PostgreSQL and native extensions are assembled from upstream native packages, normalized into Stella's bundle layout, smoke-tested, and published as release assets. Linux bundles wrap PGDG's non-relocatable Debian packages with a small `initdb` wrapper and patched ELF rpaths so Stella can extract and run them from its cache directory. Stella should not rebuild PostgreSQL inside its normal CI, and the Stella source repository should not carry large runtime blobs.

## Licensing warning

`pg_search` is AGPL-3.0. Publishing bundles that contain `pg_search` is an explicit distribution decision. Do not consume these artifacts unless Stella's product/license posture accepts that obligation.
