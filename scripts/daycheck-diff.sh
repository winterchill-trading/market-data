#!/usr/bin/env bash
# Compares the day-close output of two revisions of market-data over the same norm/ data.
#
#   scripts/daycheck-diff.sh [-data DIR] [-date YYYY-MM-DD] A B
#   scripts/daycheck-diff.sh -compare ROOT_A ROOT_B
#
# A and B are market-data binaries or git revisions of this repository; a revision is
# checked out into a temporary worktree and built there with `dune build`. Its
# dependencies come from the opam switch, or, when this checkout sits in a dune
# workspace next to fixed-decimal, exchange-core and parquet, from those checkouts. DIR defaults to the checked-in
# fixtures (test/fixtures/event-log-research), the date to 2026-01-01. Each side
# day-closes its own copy of DIR, then every table (trades, bbo, l2, funding, candles,
# instruments) is compared by schema and by rows with DuckDB (`EXCEPT ALL` both ways),
# so files that differ only in row groups or compression compare equal.
#
# -compare skips the day close and compares two roots that already hold Parquet tables.
# Prints one line per table and exits 1 when any table differs. Needs duckdb on PATH.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
duckdb=${DUCKDB:-duckdb}
tables=(trades bbo l2 funding candles instruments)

die() {
  echo "daycheck-diff: $*" >&2
  exit 2
}

glob_of() {
  local root=$1 table=$2
  if [ "$table" = instruments ]; then
    echo "$root/instruments/*.parquet"
  else
    echo "$root/*/*/parquet/$table/*.parquet"
  fi
}

has_files() {
  # shellcheck disable=SC2086
  compgen -G "$(glob_of "$1" "$2")" >/dev/null
}

scalar() {
  "$duckdb" :memory: -noheader -list -c "$1"
}

compare_table() {
  local a=$1 b=$2 table=$3
  local in_a=0 in_b=0
  has_files "$a" "$table" && in_a=1
  has_files "$b" "$table" && in_b=1
  if [ $in_a = 0 ] && [ $in_b = 0 ]; then
    echo "$table: no files"
    return 0
  fi
  if [ $in_a != $in_b ]; then
    echo "$table: DIFFERENT (files only in $([ $in_a = 1 ] && echo A || echo B))"
    return 1
  fi
  local ra rb
  ra="read_parquet('$(glob_of "$a" "$table")', hive_partitioning = false)"
  rb="read_parquet('$(glob_of "$b" "$table")', hive_partitioning = false)"
  local schema_a schema_b
  schema_a=$(scalar "SELECT string_agg(column_name || ' ' || column_type, ', ') FROM (DESCRIBE SELECT * FROM $ra)")
  schema_b=$(scalar "SELECT string_agg(column_name || ' ' || column_type, ', ') FROM (DESCRIBE SELECT * FROM $rb)")
  if [ "$schema_a" != "$schema_b" ]; then
    echo "$table: DIFFERENT schema"
    echo "  A: $schema_a"
    echo "  B: $schema_b"
    return 1
  fi
  local counts
  counts=$(scalar "SELECT (SELECT count(*) FROM $ra) || ' ' || (SELECT count(*) FROM $rb) || ' ' ||
    (SELECT count(*) FROM (SELECT * FROM $ra EXCEPT ALL SELECT * FROM $rb)) || ' ' ||
    (SELECT count(*) FROM (SELECT * FROM $rb EXCEPT ALL SELECT * FROM $ra))")
  read -r n_a n_b only_a only_b <<<"$counts"
  if [ "$only_a" = 0 ] && [ "$only_b" = 0 ]; then
    echo "$table: identical ($n_a rows)"
  else
    echo "$table: DIFFERENT (A $n_a rows, B $n_b rows, $only_a only in A, $only_b only in B)"
    return 1
  fi
}

compare_roots() {
  local status=0
  for table in "${tables[@]}"; do
    compare_table "$1" "$2" "$table" || status=1
  done
  return $status
}

tmp=
cleanup() {
  [ -n "$tmp" ] || return 0
  for wt in "$tmp"/wt-*; do
    [ -d "$wt" ] && git -C "$here" worktree remove --force "$wt" >/dev/null 2>&1
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

# Prints the path of a market-data binary for a binary path or a git revision.
binary_of() {
  local side=$1 spec=$2
  if [ -f "$spec" ] && [ -x "$spec" ]; then
    echo "$spec"
    return
  fi
  local found
  found=$(command -v "$spec" 2>/dev/null || true)
  if [ -n "$found" ] && [ -f "$found" ]; then
    echo "$found"
    return
  fi
  git -C "$here" rev-parse --verify --quiet "$spec^{commit}" >/dev/null \
    || die "$spec is neither an executable nor a revision"
  local wt="$tmp/wt-$side"
  git -C "$here" worktree add --detach --quiet "$wt" "$spec"
  local parent
  parent=$(dirname "$here")
  if [ -f "$parent/dune-workspace" ]; then
    local ws="$tmp/ws-$side"
    mkdir -p "$ws"
    cp "$parent/dune-workspace" "$ws/"
    for dep in fixed-decimal exchange-core parquet; do
      ln -s "$parent/$dep" "$ws/$dep"
    done
    ln -s "$wt" "$ws/market-data"
    (unset DUNE_BUILD_DIR; dune build --root "$ws" ./market-data/bin/market_data_cli.exe >&2)
    echo "$ws/_build/default/market-data/bin/market_data_cli.exe"
  else
    (cd "$wt" && unset DUNE_BUILD_DIR && dune build --root . ./bin/market_data_cli.exe >&2)
    echo "$wt/_build/default/bin/market_data_cli.exe"
  fi
}

data=$here/test/fixtures/event-log-research
date=2026-01-01
while [ $# -gt 0 ]; do
  case $1 in
    -compare)
      [ $# = 3 ] || die "usage: -compare ROOT_A ROOT_B"
      compare_roots "$2" "$3"
      exit $?
      ;;
    -data) data=$2; shift 2 ;;
    -date) date=$2; shift 2 ;;
    -*) die "unknown flag $1" ;;
    *) break ;;
  esac
done
[ $# = 2 ] || die "usage: daycheck-diff.sh [-data DIR] [-date YYYY-MM-DD] A B"

tmp=$(mktemp -d)
for side in a b; do
  spec=$1
  shift
  bin=$(binary_of "$side" "$spec")
  mkdir -p "$tmp/$side"
  cp -RL "$data/." "$tmp/$side"
  chmod -R u+w "$tmp/$side"
  "$bin" day-close -dir "$tmp/$side" -date "$date" >/dev/null
done
compare_roots "$tmp/a" "$tmp/b"
