#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STELLA_PG_RUNTIME_SOURCE_ONLY=1 source "$REPO_ROOT/scripts/build-linux-deb.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

test_uses_official_deb_when_available() {
  local calls=()
  pg_search_deb_available() { return 0; }
  install_pg_search_from_deb() { calls+=("deb"); }
  install_pg_search_from_source() { calls+=("source"); }

  install_pg_search

  [[ "${calls[*]}" == "deb" ]] || fail "expected deb install path, got: ${calls[*]}"
}

test_falls_back_to_source_when_deb_missing() {
  local calls=()
  pg_search_deb_available() { return 1; }
  install_pg_search_from_deb() { calls+=("deb"); }
  install_pg_search_from_source() { calls+=("source"); }

  install_pg_search

  [[ "${calls[*]}" == "source" ]] || fail "expected source install path, got: ${calls[*]}"
}

test_uses_official_deb_when_available
test_falls_back_to_source_when_deb_missing
echo "ok build-linux-deb fallback selection"
