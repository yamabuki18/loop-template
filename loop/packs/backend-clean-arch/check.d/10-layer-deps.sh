#!/usr/bin/env bash
# Gate.d check (L3, backend-clean-arch): on the merged tree, lines the branch ADDED to
# CORE files must not match FORBIDDEN_IMPORT_REGEX. This is the server-side twin of the L2
# guard-layer-imports hook — the worker cannot reach or edit this file (it lives in the
# workspace, outside every worktree). cwd = merged tree; GATE_MERGE_BASE/GATE_BRANCH are set
# by gate.sh. Unconfigured -> advisory pass.
set -euo pipefail

CFG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/clean-arch.env"
CORE_DIRS=""; FORBIDDEN_IMPORT_REGEX=""
# shellcheck disable=SC1090
[ -f "$CFG" ] && source "$CFG"
if [ -z "$CORE_DIRS" ] || [ -z "$FORBIDDEN_IMPORT_REGEX" ]; then
  echo "clean-arch: CORE_DIRS/FORBIDDEN_IMPORT_REGEX not configured (gate.d/clean-arch.env) — advisory pass."
  exit 0
fi

# shellcheck disable=SC2086  # CORE_DIRS is a space-separated pathspec list by design
viol="$(git diff --unified=0 "${GATE_MERGE_BASE:?}" "${GATE_BRANCH:?}" -- $CORE_DIRS 2>/dev/null \
  | awk '/^\+\+\+ b\//{f=substr($0,7)} /^\+/ && !/^\+\+\+/ {print f ": " substr($0,2)}' \
  | grep -E "$FORBIDDEN_IMPORT_REGEX" | head -20 || true)"

if [ -n "$viol" ]; then
  echo "clean-arch: CORE gained outward dependencies (dependency direction must be inward):"
  echo "$viol" | sed 's/^/  /'
  echo "clean-arch: define a port in core and implement it in an adapter instead."
  exit 1
fi
echo "clean-arch: OK — no outward dependencies added to core ($CORE_DIRS)."
