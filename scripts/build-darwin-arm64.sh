#!/usr/bin/env bash
set -euo pipefail

POSTGRESAPP_VERSION="${POSTGRESAPP_VERSION:-2.9.5}"
POSTGRES_MAJOR="${POSTGRES_MAJOR:-18}"
POSTGRES_LABEL="${POSTGRES_LABEL:-18.4}"
PGVECTOR_LABEL="${PGVECTOR_LABEL:-0.8.2}"
PG_SEARCH_VERSION="${PG_SEARCH_VERSION:-0.24.1}"
MACOS_LABEL="${MACOS_LABEL:-sequoia}"
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

POSTGRES_DMG="Postgres-$POSTGRESAPP_VERSION-$POSTGRES_MAJOR.dmg"
POSTGRES_URL="https://github.com/PostgresApp/PostgresApp/releases/download/v$POSTGRESAPP_VERSION/$POSTGRES_DMG"
curl -fsSLo "$POSTGRES_DMG" "$POSTGRES_URL"
MOUNT_DIR="$WORK_DIR/postgresapp-mount"
mkdir -p "$MOUNT_DIR"
hdiutil attach "$POSTGRES_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -readonly >/dev/null
trap 'hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true' EXIT
APP_DIR="$(find "$MOUNT_DIR" -maxdepth 2 -name 'Postgres.app' -type d | head -n1)"
if [[ -z "$APP_DIR" ]]; then
  echo "Postgres.app not found in $POSTGRES_DMG" >&2
  exit 1
fi
rsync -a "$APP_DIR/Contents/Versions/$POSTGRES_MAJOR/" "$PREFIX/"
cp "$APP_DIR/Contents/Resources/COPYRIGHT" "$ROOT/LICENSES/postgresapp-COPYRIGHT" 2>/dev/null || true

PG_SEARCH_PKG="pg_search@$POSTGRES_MAJOR--$PG_SEARCH_VERSION.arm64_$MACOS_LABEL.pkg"
PG_SEARCH_URL="https://github.com/paradedb/paradedb/releases/download/v$PG_SEARCH_VERSION/${PG_SEARCH_PKG//@/%40}"
curl -fsSLo pg_search.pkg "$PG_SEARCH_URL"
pkgutil --expand-full pg_search.pkg pg_search-expanded
cp pg_search-expanded/Payload/lib/postgresql/pg_search.dylib "$EXT_LIB/"
cp pg_search-expanded/Payload/share/postgresql@"$POSTGRES_MAJOR"/extension/pg_search* "$EXT_SHARE/"
cp pg_search-expanded/Scripts/LICENSE "$ROOT/LICENSES/pg_search-LICENSE" 2>/dev/null || true

# Postgres.app ships pgvector; copy it into Stella's extension overlay so the
# bundle is self-describing even when extension_control_path is restricted.
cp "$PREFIX/lib/postgresql/vector.dylib" "$EXT_LIB/"
cp "$PREFIX/share/postgresql/extension"/vector* "$EXT_SHARE/"

cat > "$ROOT/manifest.json" <<JSON
{
  "schema": 1,
  "name": "stella-pg-runtime",
  "platform": "darwin-arm64",
  "runtime_source": "Postgres.app $POSTGRESAPP_VERSION",
  "postgres": "$POSTGRES_LABEL",
  "pgvector": "$PGVECTOR_LABEL",
  "pg_search": "$PG_SEARCH_VERSION",
  "license_warning": "pg_search is AGPL-3.0; distribution is an explicit product/legal decision."
}
JSON

DATA="$WORK_DIR/smoke-data"
PORT="${SMOKE_PORT:-55432}"
"$PREFIX/bin/initdb" -D "$DATA" --no-locale --encoding=UTF8 >/dev/null
"$PREFIX/bin/pg_ctl" -D "$DATA" -l "$WORK_DIR/smoke.log" -o "-p $PORT -c extension_control_path='$EXT_SHARE:$PREFIX/share/postgresql:\$system' -c dynamic_library_path='$EXT_LIB:$PREFIX/lib/postgresql' -c shared_preload_libraries='pg_search'" start -w >/dev/null
cleanup() {
  "$PREFIX/bin/pg_ctl" -D "$DATA" stop -m fast -w >/dev/null 2>&1 || true
  hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
}
trap cleanup EXIT
"$PREFIX/bin/psql" -p "$PORT" -d postgres -v ON_ERROR_STOP=1 <<'SQL'
SELECT name, default_version FROM pg_available_extensions WHERE name IN ('pg_search','vector') ORDER BY name;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_search;
SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_search','vector') ORDER BY extname;
SQL
"$PREFIX/bin/pg_ctl" -D "$DATA" stop -m fast -w >/dev/null

ARCHIVE="stella-pg-runtime-pg$POSTGRES_LABEL-pgvector$PGVECTOR_LABEL-pgsearch$PG_SEARCH_VERSION-darwin-arm64-postgresapp.tar.zst"
tar --zstd -cf "$OUT_DIR/$ARCHIVE" -C "$ROOT" .
shasum -a 256 "$OUT_DIR/$ARCHIVE" > "$OUT_DIR/$ARCHIVE.sha256"
echo "$OUT_DIR/$ARCHIVE"
