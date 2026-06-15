#!/usr/bin/env bash
# Copy this to <your-repo>/harness/check.sh and COMMIT it. The acceptance gate runs it in a
# clean container on the trial-merged result; any non-zero exit blocks the merge (land.sh).
# Keep it fast and deterministic. Split blocking vs advisory yourself (advisory = don't exit
# non-zero; just print).
set -euo pipefail

# --- examples: replace with your project's real checks ---
# npm ci
# npm run typecheck
# npm run lint
# npm test
#
# (Python) pip install -e . && python -m pytest -q
# (Go)     go vet ./... && go test ./...

echo "harness/check.sh: TODO — add your project's blocking checks here"
