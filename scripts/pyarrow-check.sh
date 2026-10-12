#!/usr/bin/env bash
# Day-closes the checked-in fixtures into a temporary directory and runs the pyarrow
# type test of examples/query.py over them.
#   scripts/pyarrow-check.sh [MARKET_DATA_BINARY]
# Needs python3 with pyarrow, pandas and duckdb.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bin=${1:-$here/_build/default/bin/market_data_cli.exe}
python=${PYTHON:-python3}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
roots=()
for fixture in event-log-research event-log-v1; do
  mkdir -p "$tmp/$fixture"
  cp -R "$here/test/fixtures/$fixture/." "$tmp/$fixture"
  "$bin" day-close -dir "$tmp/$fixture" -date 2026-01-01 >/dev/null
  roots+=("$tmp/$fixture")
done
"$python" "$here/examples/test_query.py" "${roots[@]}"
