#!/usr/bin/env bash
# Make this template reusable elsewhere. Two modes:
#
#   ./control/scaffold.sh <target-dir> [repo-url]
#       Lay the loop template into <target-dir> (control/ + skills/ + memory/ + README/.gitignore),
#       ready for you to fill in config.env/secret.env/skills and run ./control/setup.sh there.
#       If [repo-url] is given it is recorded as a hint for setup.sh (which clones canonical).
#
#   ./control/scaffold.sh --install-host-guard
#       Merge the OPTIONAL host secret-guard hooks (host-harness/settings.json) into this
#       project's .claude/settings.json. Only needed if you run an interactive supervisor Claude
#       on the host. See control/host-harness/README.md.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

if [ "${1:-}" = "--install-host-guard" ]; then
  dest="$ROOT/.claude/settings.json"
  mkdir -p "$ROOT/.claude"
  chmod +x "$CONTROL_DIR/host-harness/harness-guard-secrets" 2>/dev/null || true
  add="$(jq '.hooks' "$CONTROL_DIR/host-harness/settings.json")"
  if [ -f "$dest" ]; then
    tmp="$(mktemp)"
    jq --argjson add "$add" '.hooks = ((.hooks // {}) * $add)' "$dest" > "$tmp" && mv "$tmp" "$dest"
    echo "scaffold: merged host-guard hooks into $dest"
  else
    jq -n --argjson add "$add" '{hooks:$add}' > "$dest"
    echo "scaffold: wrote $dest with host-guard hooks"
  fi
  echo "scaffold: host secret-guard active for an interactive supervisor Claude in $ROOT."
  exit 0
fi

TARGET="${1:?usage: scaffold.sh <target-dir> [repo-url]   |   scaffold.sh --install-host-guard}"
REPO="${2:-}"
mkdir -p "$TARGET"
[ -z "$(ls -A "$TARGET" 2>/dev/null)" ] || echo "scaffold: note — $TARGET is not empty; existing files are kept, template files are added."

echo "scaffold: copying template into $TARGET …"
cp -r "$CONTROL_DIR"            "$TARGET/control"
cp -r "$SKILLS_DIR"            "$TARGET/skills"  2>/dev/null || true
cp -r "$MEMORY_DIR"            "$TARGET/memory"  2>/dev/null || true
[ -f "$ROOT/.gitignore" ] && cp "$ROOT/.gitignore" "$TARGET/.gitignore"
[ -f "$ROOT/README.md" ]  && cp "$ROOT/README.md"  "$TARGET/README.md"
# Never carry secrets or per-run state into a new project.
rm -f  "$TARGET/control/secret.env" "$TARGET/control/secret.broker.env" \
       "$TARGET/control/secret.gate.env" "$TARGET/control/.source-repo"
rm -rf "$TARGET/state" "$TARGET/exchange" "$TARGET/review" "$TARGET/canonical"
# Fresh memory for the new project.
printf '# BACKLOG\n\n## Goals\n- [ ] <first goal>\n\n## Done\n' > "$TARGET/memory/backlog.md" 2>/dev/null || true

[ -n "$REPO" ] && echo "$REPO" > "$TARGET/control/.source-repo"

# Restore exec bits (cp/tar may have dropped them).
chmod +x "$TARGET"/control/*.sh "$TARGET"/control/worker-prepare \
         "$TARGET"/control/hooks/* "$TARGET"/control/worker-harness/harness-* \
         "$TARGET"/control/host-harness/harness-* 2>/dev/null || true

cat <<EOF

scaffold: done. Next, in $TARGET:
  1. edit control/config.env        (PROJECT_NAME, BASE_BRANCH, CHECK_CMD, loop knobs)
  2. cp control/secret.env.example control/secret.env && chmod 600 control/secret.env
     -> put a DISPOSABLE, minimally-scoped worker key in it (never your personal key)
  3. fill in skills/VISION.md, skills/ARCHITECTURE.md, skills/RULES.md
  4. bash ./control/setup.sh ${REPO:+$REPO}
  5. write goals in memory/backlog.md, then ./control/up.sh  (loop pane is pre-armed)
EOF
