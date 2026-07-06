#!/usr/bin/env bash
# One-time setup (fast in v3 — no image build). After this you only run up.sh.
#   ./control/setup.sh [<existing-repo-url-or-path>]
# If a source repo is given, canonical is cloned from it; otherwise an empty repo is created.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# Self-heal exec bits (a copied/extracted tree may carry them as non-executable). First run as:
#   bash ./control/setup.sh
chmod +x "$CONTROL_DIR"/*.sh \
         "$CONTROL_DIR"/worker-harness/harness-* \
         "$CONTROL_DIR"/host-harness/harness-* 2>/dev/null || true

# A repo URL can also be recorded by `loop init` / scaffold.sh in .source-repo.
SRC="${1:-}"
[ -z "$SRC" ] && [ -f "$CONFIG_DIR/.source-repo" ]  && SRC="$(cat "$CONFIG_DIR/.source-repo")"
[ -z "$SRC" ] && [ -f "$CONTROL_DIR/.source-repo" ] && SRC="$(cat "$CONTROL_DIR/.source-repo")"

echo "[1/5] host tooling ..."
command -v git   >/dev/null 2>&1 || die "git not found"
command -v jq    >/dev/null 2>&1 || die "jq not found (required by hooks and the loop)"
command -v claude >/dev/null 2>&1 || echo "  WARNING: claude CLI not found — planner/workers cannot run."
command -v herdr >/dev/null 2>&1 || echo "  WARNING: herdr not found — install: curl -fsSL https://herdr.dev/install.sh | sh"

echo "[2/5] secrets (sops+age) ..."
if [ "$SECRET_BACKEND" = sops ] && command -v sops >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
  "$CONTROL_DIR/secrets.sh" init --if-needed || true
else
  echo "  NOTE: sops/age not ready — set up later with: loop secrets init   (doctor.sh has details)"
fi

echo "[3/5] creating directories ..."
mkdir -p "$STATE_DIR" "$WORKTREES_DIR" "$REVIEW_DIR" "$LOG_DIR" "$SKILLS_DIR" "$MEMORY_DIR"

echo "[4/5] canonical repo ..."
if [ ! -d "$CANONICAL/.git" ]; then
  if [ -n "$SRC" ]; then
    git clone "$SRC" "$CANONICAL"
  else
    mkdir -p "$CANONICAL"
    git -C "$CANONICAL" init -b "$BASE_BRANCH" >/dev/null
    git -C "$CANONICAL" commit --allow-empty -m "init" >/dev/null
  fi
fi
# D4: fail loudly NOW if the cloned repo's branches don't include BASE_BRANCH, instead of an
# inscrutable failure later in spawn.sh's worktree creation.
git -C "$CANONICAL" show-ref --verify --quiet "refs/heads/$BASE_BRANCH" \
  || die "canonical has no branch '$BASE_BRANCH'. Set BASE_BRANCH in config.env to the repo's default branch, or create it: git -C canonical checkout -b $BASE_BRANCH"

repo_map_refresh   # first structural map for the planner (kept fresh by every land)

echo "[5/5] preflight ..."
"$CONTROL_DIR/doctor.sh" --quick || true
secret_present worker || echo "  NOTE: add your Claude credential:  claude setup-token && loop secrets edit worker"
echo "  Write goals in memory/backlog.md, then start:   ./control/up.sh"
