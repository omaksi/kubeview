#!/usr/bin/env bash
set -euo pipefail

# Guard against SwiftPM's silent orphan-file trap: a .swift file under
# Sources/ that no declared target's source set covers is dropped from the
# build with NO warning and NO error - it simply never compiles. Ask
# SwiftPM itself which files it claims (swift package describe), rather
# than parsing Package.swift, so this stays correct as targets are added.
#
# Usage: ./scripts/check-sources.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DESCRIBE="$(swift package describe --type json)"

CLAIMED="$(jq -r '.targets[] as $t | $t.sources[] | "\($t.path)/\(.)"' <<<"$DESCRIBE" | sort)"
# Tests/ counts too: a misplaced test file, or a directory whose name does not
# match its target, is dropped just as silently as one under Sources/.
ON_DISK="$(find Sources Tests -name '*.swift' 2>/dev/null | sort)"

ORPHANS="$(comm -13 <(printf '%s\n' "$CLAIMED") <(printf '%s\n' "$ON_DISK"))"

if [ -n "$ORPHANS" ]; then
  echo "error: these .swift files are not claimed by any target and will be SILENTLY dropped from the build:" >&2
  echo "$ORPHANS" | sed 's/^/  /' >&2
  exit 1
fi

echo "OK: every .swift file under Sources/ and Tests/ is covered by a declared target."
