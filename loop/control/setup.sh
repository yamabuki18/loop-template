#!/usr/bin/env bash
# One-time setup. Slow the first time (builds the image); after this you only run up.sh.
#   ./control/setup.sh [<existing-repo-url-or-path>]
# If a source repo is given, canonical is cloned from it; otherwise an empty repo is created.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# Self-heal exec bits (a copied/extracted tree may carry them as non-executable). First run as:
#   bash ./control/setup.sh
chmod +x "$CONTROL_DIR"/*.sh "$CONTROL_DIR"/worker-prepare \
         "$CONTROL_DIR"/hooks/* "$CONTROL_DIR"/worker-harness/harness-* \
         "$CONTROL_DIR"/host-harness/harness-* 2>/dev/null || true

# Tighten secret perms if present (the disposable worker key should not be world-readable).
[ -f "$CONTROL_DIR/secret.env" ] && chmod 600 "$CONTROL_DIR/secret.env" 2>/dev/null || true

# A repo URL can also be recorded by scaffold.sh in control/.source-repo.
SRC="${1:-}"; [ -z "$SRC" ] && [ -f "$CONTROL_DIR/.source-repo" ] && SRC="$(cat "$CONTROL_DIR/.source-repo")"

echo "[1/5] building worker image ($IMAGE)${CLAUDE_CODE_VERSION:+ @ claude-code $CLAUDE_CODE_VERSION} — slow the first time ..."
docker build ${CLAUDE_CODE_VERSION:+--build-arg CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION"} -t "$IMAGE" "$CONTROL_DIR"

echo "[2/5] creating directories ..."
mkdir -p "$STATE_DIR" "$EXCHANGE_DIR" "$REVIEW_DIR" "$LOG_DIR" "$SKILLS_DIR" "$MEMORY_DIR"

echo "[3/5] canonical repo ..."
if [ ! -d "$CANONICAL/.git" ]; then
  if [ -n "$SRC" ]; then
    git clone "$SRC" "$CANONICAL"
  else
    mkdir -p "$CANONICAL"
    git -C "$CANONICAL" init -b "$BASE_BRANCH" >/dev/null
    git -C "$CANONICAL" commit --allow-empty -m "init" >/dev/null
  fi
fi

echo "[4/5] verifying BASE_BRANCH and installing canonical hook ..."
# D4: fail loudly NOW if the cloned repo's branches don't include BASE_BRANCH, instead of an
# inscrutable failure later in spawn.sh's `git branch -f "$BRANCH" "$BASE_BRANCH"`.
git -C "$CANONICAL" show-ref --verify --quiet "refs/heads/$BASE_BRANCH" \
  || die "canonical has no branch '$BASE_BRANCH'. Set BASE_BRANCH in control/config.env to the repo's default branch, or create it: git -C canonical checkout -b $BASE_BRANCH"
cp "$CONTROL_DIR/hooks/pre-receive" "$CANONICAL/.git/hooks/pre-receive"
chmod +x "$CANONICAL/.git/hooks/pre-receive"

echo "[5/5] preflight ..."
"$CONTROL_DIR/doctor.sh" --quick || true
[ -f "$CONTROL_DIR/secret.env" ] || echo "  NOTE: create control/secret.env from secret.env.example (DISPOSABLE worker key), then chmod 600."
echo "  Write goals in memory/backlog.md, then start:   ./control/up.sh"
