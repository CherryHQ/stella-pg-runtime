#!/usr/bin/env bash
set -euo pipefail

PG_VERSION="${PG_VERSION:-18.3.0}"
PGVECTOR_VERSION="${PGVECTOR_VERSION:-0.8.3}"
PG_SEARCH_VERSION="${PG_SEARCH_VERSION:-0.24.1}"
OUT_DIR="${OUT_DIR:-$PWD/dist}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
ROOT="$WORK_DIR/root"
PREFIX="$ROOT/postgres"
EXT_LIB="$ROOT/extensions/lib"
EXT_SHARE="$ROOT/extensions/share/extension"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "this script must run natively on darwin/arm64" >&2
  exit 1
fi

mkdir -p "$OUT_DIR" "$PREFIX" "$EXT_LIB" "$EXT_SHARE" "$ROOT/LICENSES"

cd "$WORK_DIR"

curl -fsSLO "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2"
tar -xjf "postgresql-$PG_VERSION.tar.bz2"
cd "postgresql-$PG_VERSION"
./configure --prefix="$PREFIX" --without-readline --without-icu --without-zlib
make -j"$(sysctl -n hw.ncpu)"
make install
cp COPYRIGHT "$ROOT/LICENSES/postgresql-COPYRIGHT"

cd "$WORK_DIR"
curl -fsSL "https://github.com/pgvector/pgvector/archive/refs/tags/v$PGVECTOR_VERSION.tar.gz" | tar -xz
cd "pgvector-$PGVECTOR_VERSION"
make PG_CONFIG="$PREFIX/bin/pg_config"
make install PG_CONFIG="$PREFIX/bin/pg_config"
cp LICENSE "$ROOT/LICENSES/pgvector-LICENSE"

cd "$WORK_DIR"
curl -fsSL "https://github.com/paradedb/paradedb/archive/refs/tags/v$PG_SEARCH_VERSION.tar.gz" | tar -xz
cd "paradedb-$PG_SEARCH_VERSION/pg_search"
cargo install --locked cargo-pgrx --version 0.18.1 || true
cargo pgrx init --pg18 "$PREFIX/bin/pg_config" --no-run
cargo pgrx install --release --pg-config "$PREFIX/bin/pg_config"
cp LICENSE "$ROOT/LICENSES/pg_search-LICENSE"

cp "$PREFIX/lib/vector.dylib" "$EXT_LIB/"
cp "$PREFIX/lib/pg_search.dylib" "$EXT_LIB/"
cp "$PREFIX/share/extension"/vector* "$EXT_SHARE/"
cp "$PREFIX/share/extension"/pg_search* "$EXT_SHARE/"
rm -f "$PREFIX/lib/vector.dylib" "$PREFIX/lib/pg_search.dylib"
rm -f "$PREFIX/share/extension"/vector* "$PREFIX/share/extension"/pg_search*
strip -x "$EXT_LIB/pg_search.dylib" || true
strip -x "$EXT_LIB/vector.dylib" || true

cat > "$ROOT/manifest.json" <<JSON
{
  "schema": 1,
  "name": "stella-pg-runtime",
  "platform": "darwin-arm64",
  "postgres": "$PG_VERSION",
  "pgvector": "$PGVECTOR_VERSION",
  "pg_search": "$PG_SEARCH_VERSION",
  "license_warning": "pg_search is AGPL-3.0; distribution is an explicit product/legal decision."
}
JSON

ARCHIVE="stella-pg-runtime-pg$PG_VERSION-pgvector$PGVECTOR_VERSION-pgsearch$PG_SEARCH_VERSION-darwin-arm64.tar.zst"
tar --zstd -cf "$OUT_DIR/$ARCHIVE" -C "$ROOT" .
shasum -a 256 "$OUT_DIR/$ARCHIVE" > "$OUT_DIR/$ARCHIVE.sha256"
echo "$OUT_DIR/$ARCHIVE"
