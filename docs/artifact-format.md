# Artifact format

Release assets are named:

```text
stella-pg-runtime-<version>-<goos>-<goarch>-<source>.tar.zst
stella-pg-runtime-<version>-checksums.txt
stella-pg-runtime-<version>-manifest.json
```

Each archive extracts to:

```text
postgres/bin/pg_ctl
postgres/bin/postgres
postgres/lib/
postgres/share/
extensions/lib/vector.{so,dylib,dll}
extensions/lib/pg_search.{so,dylib,dll}
extensions/share/extension/*.control
extensions/share/extension/*.sql
LICENSES/
manifest.json
```

Consumers must verify SHA-256 before embedding or executing the bundle.
