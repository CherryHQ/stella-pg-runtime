#!/usr/bin/env bash
set -euo pipefail

DISTRO="${DISTRO:-bookworm}"
POSTGRES_MAJOR="${POSTGRES_MAJOR:-18}"
POSTGRES_LABEL="${POSTGRES_LABEL:-18.4}"
PGVECTOR_LABEL="${PGVECTOR_LABEL:-0.8.2}"
PG_SEARCH_VERSION="${PG_SEARCH_VERSION:-0.24.1}"
OUT_DIR="${OUT_DIR:-$PWD/dist}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
ROOT="$WORK_DIR/root"
PREFIX="$ROOT/postgres"
PG_LIB="$PREFIX/lib/postgresql"
PG_SHARE="$PREFIX/share/postgresql"
EXT_LIB="$ROOT/extensions/lib"
EXT_SHARE="$ROOT/extensions/share/extension"
RUNTIME_LIB="$PREFIX/lib/runtime"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "this script must run on Linux" >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "this script must run as root inside a disposable build container" >&2
  exit 1
fi

case "$(dpkg --print-architecture)" in
  amd64) GOARCH="amd64"; PARADE_ARCH="amd64" ;;
  arm64) GOARCH="arm64"; PARADE_ARCH="arm64" ;;
  *) echo "unsupported Debian architecture: $(dpkg --print-architecture)" >&2; exit 1 ;;
esac

case "$DISTRO" in
  bookworm|trixie|noble) ;;
  *) echo "unsupported distro: $DISTRO" >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release patchelf zstd file xz-utils
install -d /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] https://apt.postgresql.org/pub/repos/apt ${DISTRO}-pgdg main" > /etc/apt/sources.list.d/pgdg.list
apt-get update
apt-get install -y --no-install-recommends "postgresql-$POSTGRES_MAJOR" "postgresql-client-$POSTGRES_MAJOR" "postgresql-$POSTGRES_MAJOR-pgvector"

mkdir -p "$PG_LIB" "$PG_SHARE" "$EXT_LIB" "$EXT_SHARE" "$RUNTIME_LIB" "$ROOT/LICENSES" "$OUT_DIR"
cp -a "/usr/lib/postgresql/$POSTGRES_MAJOR/bin" "$PREFIX/"
cp -a "/usr/lib/postgresql/$POSTGRES_MAJOR/lib/." "$PG_LIB/"
cp -a "/usr/share/postgresql/$POSTGRES_MAJOR/." "$PG_SHARE/"
cp -a /usr/share/doc/postgresql-common/copyright "$ROOT/LICENSES/postgresql-common-copyright" 2>/dev/null || true
cp -a "/usr/share/doc/postgresql-$POSTGRES_MAJOR/copyright" "$ROOT/LICENSES/postgresql-copyright" 2>/dev/null || true
cp -a "/usr/share/doc/postgresql-$POSTGRES_MAJOR-pgvector/copyright" "$ROOT/LICENSES/pgvector-copyright" 2>/dev/null || true

PG_SEARCH_DEB="postgresql-${POSTGRES_MAJOR}-pg-search_${PG_SEARCH_VERSION}-1PARADEDB-${DISTRO}_${PARADE_ARCH}.deb"
PG_SEARCH_URL="https://github.com/paradedb/paradedb/releases/download/v${PG_SEARCH_VERSION}/${PG_SEARCH_DEB}"
curl -fsSLo "$WORK_DIR/$PG_SEARCH_DEB" "$PG_SEARCH_URL"
dpkg-deb -x "$WORK_DIR/$PG_SEARCH_DEB" "$WORK_DIR/pg_search"
cp "$WORK_DIR/pg_search/usr/lib/postgresql/$POSTGRES_MAJOR/lib/pg_search.so" "$EXT_LIB/"
cp "$WORK_DIR/pg_search/usr/share/postgresql/$POSTGRES_MAJOR/extension"/pg_search* "$EXT_SHARE/"
cp -a "$WORK_DIR/pg_search/usr/share/doc"/*/copyright "$ROOT/LICENSES/pg_search-copyright" 2>/dev/null || true

cp "$PG_LIB/vector.so" "$EXT_LIB/"
cp "$PG_SHARE/extension"/vector* "$EXT_SHARE/"

mv "$PREFIX/bin/initdb" "$PREFIX/bin/initdb.real"
cat > "$PREFIX/bin/initdb" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$BIN_DIR/initdb.real" "$@" \
  -L "$BIN_DIR/../share/postgresql" \
  -c "dynamic_library_path=$BIN_DIR/../lib/postgresql"
WRAPPER
chmod 0755 "$PREFIX/bin/initdb"

collect_deps() {
  local file="$1"
  ldd "$file" 2>/dev/null | awk '
    /=> \/.* \(/ {print $3}
    /^\s*\/.* \(/ {print $1}
  '
}

while IFS= read -r file; do
  while IFS= read -r dep; do
    case "$dep" in
      /lib/*|/usr/lib/*)
        cp -L "$dep" "$RUNTIME_LIB/" 2>/dev/null || true
        ;;
    esac
  done < <(collect_deps "$file")
done < <(find "$PREFIX/bin" "$PG_LIB" "$EXT_LIB" -type f \( -perm -111 -o -name '*.so' \))

while IFS= read -r exe; do
  if file "$exe" | grep -q 'ELF'; then
    patchelf --set-rpath '$ORIGIN/../lib/runtime:$ORIGIN/../lib/postgresql' "$exe" 2>/dev/null || true
  fi
done < <(find "$PREFIX/bin" -type f -perm -111)

while IFS= read -r lib; do
  if file "$lib" | grep -q 'ELF'; then
    patchelf --set-rpath '$ORIGIN:$ORIGIN/../runtime' "$lib" 2>/dev/null || true
  fi
done < <(find "$PG_LIB" -type f -name '*.so')

while IFS= read -r lib; do
  if file "$lib" | grep -q 'ELF'; then
    patchelf --set-rpath '$ORIGIN:$ORIGIN/../../postgres/lib/runtime:$ORIGIN/../../postgres/lib/postgresql' "$lib" 2>/dev/null || true
  fi
done < <(find "$EXT_LIB" -type f -name '*.so')

cat > "$ROOT/manifest.json" <<JSON
{
  "schema": 1,
  "name": "stella-pg-runtime",
  "platform": "linux-$GOARCH",
  "runtime_source": "PGDG ${DISTRO}",
  "distro": "$DISTRO",
  "postgres": "$POSTGRES_LABEL",
  "pgvector": "$PGVECTOR_LABEL",
  "pg_search": "$PG_SEARCH_VERSION",
  "license_warning": "pg_search is AGPL-3.0; distribution is an explicit product/legal decision."
}
JSON

chmod a+rx "$WORK_DIR" "$ROOT" "$PREFIX"
chmod -R a+rX "$ROOT"
DATA="$WORK_DIR/smoke-data"
SMOKE_LOG="$WORK_DIR/smoke.log"
PORT="${SMOKE_PORT:-55432}"
install -d -o postgres -g postgres "$DATA"
touch "$SMOKE_LOG"
chown postgres:postgres "$SMOKE_LOG"
runuser -u postgres -- "$PREFIX/bin/initdb" -D "$DATA" --no-locale --encoding=UTF8 >/dev/null
runuser -u postgres -- "$PREFIX/bin/pg_ctl" -D "$DATA" -l "$SMOKE_LOG" -o "-p $PORT -c extension_control_path='$ROOT/extensions/share:$PG_SHARE:\$system' -c dynamic_library_path='$EXT_LIB:$PG_LIB' -c shared_preload_libraries='pg_search'" start -w >/dev/null
cleanup() {
  runuser -u postgres -- "$PREFIX/bin/pg_ctl" -D "$DATA" stop -m fast -w >/dev/null 2>&1 || true
}
trap cleanup EXIT
runuser -u postgres -- "$PREFIX/bin/psql" -p "$PORT" -d postgres -v ON_ERROR_STOP=1 <<'SQL'
SELECT name, default_version FROM pg_available_extensions WHERE name IN ('pg_search','vector') ORDER BY name;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_search;
SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_search','vector') ORDER BY extname;
SQL
runuser -u postgres -- "$PREFIX/bin/pg_ctl" -D "$DATA" stop -m fast -w >/dev/null

ARCHIVE="stella-pg-runtime-pg${POSTGRES_LABEL}-pgvector${PGVECTOR_LABEL}-pgsearch${PG_SEARCH_VERSION}-linux-${GOARCH}-${DISTRO}.tar.zst"
tar --zstd -cf "$OUT_DIR/$ARCHIVE" -C "$ROOT" postgres extensions LICENSES manifest.json
(
  cd "$OUT_DIR"
  sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
)
echo "$OUT_DIR/$ARCHIVE"
