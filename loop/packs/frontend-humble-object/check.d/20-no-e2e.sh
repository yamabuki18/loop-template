#!/usr/bin/env bash
# Gate.d check (L3, frontend-humble-object): the worker branch must not ADD E2E-suite
# files. Server-side twin of guard-no-e2e — lives in the workspace, worker-unreachable.
# cwd = merged tree; GATE_MERGE_BASE/GATE_BRANCH are set by gate.sh.
set -euo pipefail

CFG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/frontend-testing.env"
E2E_BLOCK_REGEX=''
# shellcheck disable=SC1090
[ -f "$CFG" ] && source "$CFG"
if [ -z "$E2E_BLOCK_REGEX" ]; then
  echo "no-e2e: E2E_BLOCK_REGEX not configured (gate.d/frontend-testing.env) — advisory pass."
  exit 0
fi

added="$(git diff --diff-filter=A --name-only "${GATE_MERGE_BASE:?}" "${GATE_BRANCH:?}" 2>/dev/null \
  | grep -E "$E2E_BLOCK_REGEX" | head -20 || true)"

if [ -n "$added" ]; then
  echo "no-e2e: branch adds E2E-suite artifacts (project rule: humble-object unit tests + supervisor smoke only):"
  echo "$added" | sed 's/^/  /'
  exit 1
fi
echo "no-e2e: OK — no E2E-suite files added."
