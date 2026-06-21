# stella-pg-runtime

Native PostgreSQL runtime bundles for Stella.

This repository builds and publishes per-platform PostgreSQL runtime archives that Stella can download during release builds and embed into the Stella binary.

## Bundle contents

Current target stack:

- PostgreSQL 18.3.0
- pgvector 0.8.3
- pg_search 0.24.1

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

PostgreSQL and native extensions must be built on native runners with matching `pg_config`. Stella should not rebuild PostgreSQL inside its normal CI, and the Stella source repository should not carry large runtime blobs.

## Licensing warning

`pg_search` is AGPL-3.0. Publishing bundles that contain `pg_search` is an explicit distribution decision. Do not consume these artifacts unless Stella's product/license posture accepts that obligation.
