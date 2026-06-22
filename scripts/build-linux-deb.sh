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
# PGDG compiles fixed absolute paths (bindir=/usr/lib/postgresql/<major>/bin,
# datadir=/usr/share/postgresql/<major>); the postgres backend only finds its
# share dir (timezonesets, bki) at runtime by relocating those paths relative to
# its own executable. Relocation needs the compiled bindir<->sharedir suffixes
# preserved, so the bundle mirrors /usr under $PREFIX instead of flattening to
# postgres/bin + postgres/share. A flat layout makes the backend fall back to the
# absolute /usr path, which does not exist on the host (see issue: timezonesets).
PREFIX="$ROOT/postgres"
PG_HOME="$PREFIX/lib/postgresql/$POSTGRES_MAJOR"
PG_BIN="$PG_HOME/bin"
PG_LIB="$PG_HOME/lib"
PG_SHARE="$PREFIX/share/postgresql/$POSTGRES_MAJOR"
EXT_LIB="$ROOT/extensions/lib"
EXT_SHARE="$ROOT/extensions/share/extension"
RUNTIME_LIB="$PREFIX/lib/runtime"

pg_search_deb_name() {
  printf 'postgresql-%s-pg-search_%s-1PARADEDB-%s_%s.deb' "$POSTGRES_MAJOR" "$PG_SEARCH_VERSION" "$DISTRO" "$PARADE_ARCH"
}

pg_search_deb_url() {
  printf 'https://github.com/paradedb/paradedb/releases/download/v%s/%s' "$PG_SEARCH_VERSION" "$(pg_search_deb_name)"
}

pg_search_deb_available() {
  curl -fsSIL -o /dev/null "$(pg_search_deb_url)"
}

install_pg_search_from_deb() {
  local deb
  deb="$(pg_search_deb_name)"
  curl -fsSLo "$WORK_DIR/$deb" "$(pg_search_deb_url)"
  dpkg-deb -x "$WORK_DIR/$deb" "$WORK_DIR/pg_search"
  cp "$WORK_DIR/pg_search/usr/lib/postgresql/$POSTGRES_MAJOR/lib/pg_search.so" "$EXT_LIB/"
  cp "$WORK_DIR/pg_search/usr/share/postgresql/$POSTGRES_MAJOR/extension"/pg_search* "$EXT_SHARE/"
  cp -a "$WORK_DIR/pg_search/usr/share/doc"/*/copyright "$ROOT/LICENSES/pg_search-copyright" 2>/dev/null || true
}

install_rust_toolchain() {
  export PATH="${CARGO_HOME:-/root/.cargo}/bin:$PATH"
  if command -v cargo >/dev/null 2>&1; then
    return
  fi
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
}

install_pg_search_from_source() {
  local source_dir="$WORK_DIR/paradedb"
  apt-get install -y --no-install-recommends build-essential git clang libclang-dev pkg-config libssl-dev "postgresql-server-dev-$POSTGRES_MAJOR"
  install_rust_toolchain
  cargo install --locked cargo-pgrx --version 0.18.1
  mkdir -p "$source_dir"
  curl -fsSL "https://github.com/paradedb/paradedb/archive/refs/tags/v${PG_SEARCH_VERSION}.tar.gz" | tar -xz -C "$source_dir" --strip-components=1
  (
    cd "$source_dir"
    cargo pgrx install --package pg_search --release --pg-config "/usr/lib/postgresql/$POSTGRES_MAJOR/bin/pg_config"
  )
  cp "/usr/lib/postgresql/$POSTGRES_MAJOR/lib/pg_search.so" "$EXT_LIB/"
  cp "/usr/share/postgresql/$POSTGRES_MAJOR/extension"/pg_search* "$EXT_SHARE/"
  cp -a "$source_dir/LICENSE" "$ROOT/LICENSES/pg_search-license" 2>/dev/null || true
}

install_pg_search() {
  if pg_search_deb_available; then
    install_pg_search_from_deb
  else
    install_pg_search_from_source
  fi
}

main() {
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
    bookworm|jammy|noble|resolute|trixie) ;;
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

mkdir -p "$PG_BIN" "$PG_LIB" "$PG_SHARE" "$EXT_LIB" "$EXT_SHARE" "$RUNTIME_LIB" "$ROOT/LICENSES" "$OUT_DIR"
cp -a "/usr/lib/postgresql/$POSTGRES_MAJOR/bin/." "$PG_BIN/"
cp -a "/usr/lib/postgresql/$POSTGRES_MAJOR/lib/." "$PG_LIB/"
cp -a "/usr/share/postgresql/$POSTGRES_MAJOR/." "$PG_SHARE/"
cp -a /usr/share/doc/postgresql-common/copyright "$ROOT/LICENSES/postgresql-common-copyright" 2>/dev/null || true
cp -a "/usr/share/doc/postgresql-$POSTGRES_MAJOR/copyright" "$ROOT/LICENSES/postgresql-copyright" 2>/dev/null || true
cp -a "/usr/share/doc/postgresql-$POSTGRES_MAJOR-pgvector/copyright" "$ROOT/LICENSES/pgvector-copyright" 2>/dev/null || true

install_pg_search

cp "$PG_LIB/vector.so" "$EXT_LIB/"
cp "$PG_SHARE/extension"/vector* "$EXT_SHARE/"

# No initdb wrapper: the /usr-mirrored layout lets every binary (initdb and the
# postgres backend it spawns) relocate its own share/lib dirs, so the old
# -L/dynamic_library_path wrapper is both unnecessary and would point at the
# wrong paths under the new bin location.

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
done < <(find "$PG_BIN" "$PG_LIB" "$EXT_LIB" -type f \( -perm -111 -o -name '*.so' \))

# rpath origins below are relative to each binary's new location:
#   bin    = postgres/lib/postgresql/<major>/bin
#   pkglib = postgres/lib/postgresql/<major>/lib
#   runtime= postgres/lib/runtime
#   ext    = extensions/lib
while IFS= read -r exe; do
  if file "$exe" | grep -q 'ELF'; then
    patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN/../../../runtime' "$exe" 2>/dev/null || true
  fi
done < <(find "$PG_BIN" -type f -perm -111)

while IFS= read -r lib; do
  if file "$lib" | grep -q 'ELF'; then
    patchelf --set-rpath '$ORIGIN:$ORIGIN/../../../runtime' "$lib" 2>/dev/null || true
  fi
done < <(find "$PG_LIB" -type f -name '*.so')

while IFS= read -r lib; do
  if file "$lib" | grep -q 'ELF'; then
    patchelf --set-rpath "\$ORIGIN:\$ORIGIN/../../postgres/lib/runtime:\$ORIGIN/../../postgres/lib/postgresql/$POSTGRES_MAJOR/lib" "$lib" 2>/dev/null || true
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
runuser -u postgres -- "$PG_BIN/initdb" -D "$DATA" --no-locale --encoding=UTF8 >/dev/null
runuser -u postgres -- "$PG_BIN/pg_ctl" -D "$DATA" -l "$SMOKE_LOG" -o "-p $PORT -c extension_control_path='$ROOT/extensions/share:$PG_SHARE:\$system' -c dynamic_library_path='$EXT_LIB:$PG_LIB' -c shared_preload_libraries='pg_search'" start -w >/dev/null
cleanup() {
  runuser -u postgres -- "$PG_BIN/pg_ctl" -D "$DATA" stop -m fast -w >/dev/null 2>&1 || true
}
trap cleanup EXIT
runuser -u postgres -- "$PG_BIN/psql" -p "$PORT" -d postgres -v ON_ERROR_STOP=1 <<'SQL'
SELECT name, default_version FROM pg_available_extensions WHERE name IN ('pg_search','vector') ORDER BY name;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_search;
SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_search','vector') ORDER BY extname;
SQL
runuser -u postgres -- "$PG_BIN/pg_ctl" -D "$DATA" stop -m fast -w >/dev/null

ARCHIVE="stella-pg-runtime-pg${POSTGRES_LABEL}-pgvector${PGVECTOR_LABEL}-pgsearch${PG_SEARCH_VERSION}-linux-${GOARCH}-${DISTRO}.tar.zst"
tar --zstd -cf "$OUT_DIR/$ARCHIVE" -C "$ROOT" postgres extensions LICENSES manifest.json
(
  cd "$OUT_DIR"
  sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
)
echo "$OUT_DIR/$ARCHIVE"
}

if [[ "${STELLA_PG_RUNTIME_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
