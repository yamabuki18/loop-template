#!/usr/bin/env bash
# Create a NEW loop workspace: the thin per-project PAYLOAD (config + secrets + skills + memory
# + runtime state), while the engine (control/) stays centrally installed. Counterpart of the
# legacy scaffold.sh, which copies the WHOLE template (and therefore never receives engine
# updates). Invoked as `loop init`; runnable directly too.
#
#   ./control/init.sh <workspace-dir> [repo-url] [--name <project-name>]
#
# --name overrides the PROJECT_NAME baked into config.env (default: workspace dir basename).
# Used by here.sh, whose central workspace dirs are long path slugs — poor container names.
#
# Deliberately does NOT source lib.sh: lib.sh resolves the CURRENT workspace, and init must not
# inherit one — it creates a fresh one from the engine's templates only.
set -euo pipefail

CONTROL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$CONTROL_DIR/.." && pwd)"

WS=""; REPO=""; NAME_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME_OVERRIDE="${2:-}"; shift 2;;
    *) if [ -z "$WS" ]; then WS="$1"; else REPO="$1"; fi; shift;;
  esac
done
[ -n "$WS" ] || { echo "usage: loop init <workspace-dir> [repo-url] [--name <project-name>]" >&2; exit 1; }

mkdir -p "$WS"
WS="$(cd "$WS" && pwd)"
[ -f "$WS/.loop-workspace" ] && { echo "init: $WS is already a loop workspace — nothing to do."; exit 0; }
[ "$WS" = "$ENGINE" ] && { echo "init: refusing to turn the engine directory itself into a workspace." >&2; exit 1; }

# PROJECT_NAME namespaces the herdr workspace / notifications, so it MUST differ between
# workspaces — derive it from the directory name (sanitized) instead of a shared default.
name="$(printf '%s' "${NAME_OVERRIDE:-$(basename "$WS")}" \
        | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/^-*//' -e 's/-*$//')"
[ -n "$name" ] || name="loopws"

echo "init: creating workspace '$name' in $WS (engine: $ENGINE)"

# config: the engine's config.env is the documented template; only PROJECT_NAME is customized.
sed "s/^PROJECT_NAME=.*/PROJECT_NAME=$name       # auto-set by loop init (namespaces the herdr workspace)/" \
  "$CONTROL_DIR/config.env" > "$WS/config.env"
cp "$CONTROL_DIR/secret.worker.env.example" "$WS/secret.worker.env.example"
cp "$CONTROL_DIR/secret.gate.env.example"   "$WS/secret.gate.env.example"   2>/dev/null || true
cp "$CONTROL_DIR/secret.codex.env.example"  "$WS/secret.codex.env.example"  2>/dev/null || true

# Project knowledge templates (the loop reads these every cycle — fill them in).
mkdir -p "$WS/skills" "$WS/memory"
for f in "$ENGINE"/skills/*.md;  do [ -e "$WS/skills/$(basename "$f")" ] || cp "$f" "$WS/skills/"; done
[ -f "$WS/memory/PROGRESS.md" ] || cp "$ENGINE/memory/PROGRESS.md" "$WS/memory/PROGRESS.md"
[ -f "$WS/memory/backlog.md" ]  || cp "$ENGINE/memory/backlog.md"  "$WS/memory/backlog.md"

# Never let secrets or runtime state get committed from a workspace. Encrypted *.sops.env MAY
# be committed if your team shares age recipients — opt in by removing those lines (README).
cat > "$WS/.gitignore" <<'EOF'
# loop workspace — secrets and runtime state stay out of git
secret.*.sops.env
secret.*.op.env
.sops.yaml
secret.env
secret.worker.env
secret.gate.env
secret.codex.env
.source-repo
state/
worktrees/
canonical/
review/
EOF

[ -n "$REPO" ] && echo "$REPO" > "$WS/.source-repo"

# The marker lib.sh searches for (values are informational; presence is what matters).
cat > "$WS/.loop-workspace" <<EOF
ENGINE=$ENGINE
ENGINE_VERSION=$(cat "$ENGINE/VERSION" 2>/dev/null || echo '?')
CREATED=$(date -u +%FT%TZ)
EOF

cat <<EOF

init: workspace ready. Next, in $WS:
  1. \$EDITOR config.env                 (BASE_BRANCH, CHECK_CMD, loop knobs — PROJECT_NAME is set)
  2. claude setup-token && loop secrets init && loop secrets edit worker
     -> the credential lives sops-encrypted (never a plaintext file)
  3. \$EDITOR skills/VISION.md skills/ARCHITECTURE.md skills/RULES.md
  4. loop setup ${REPO:+$REPO}          (creates canonical — no image build in v3)
  5. write goals in memory/backlog.md, then:  loop up
EOF
