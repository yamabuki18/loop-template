#!/usr/bin/env bash
# Zero-footprint attach for daily development. Run from anywhere inside a project:
#
#   cd ~/dev/myproject && loop here
#
# Creates (or finds) this project's loop workspace OUTSIDE the repo, at
#   $LOOP_HOME/workspaces/<path-slug>/
# so the project's git never sees a single loop file. canonical is cloned FROM the project's
# local repo; results flow back as a branch via `loop publish` (never into the working tree),
# and your own new commits flow forward via `loop refresh`. After attaching, every `loop`
# command run from inside the project resolves to this workspace automatically (lib.sh).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PROJ="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
WS="$LOOP_HOME/workspaces/$(path_slug "$PROJ")"

if [ -f "$WS/.loop-workspace" ]; then
  todo="$(grep -c '^- \[ \] ' "$WS/memory/backlog.md" 2>/dev/null || true)"; todo="${todo:-0}"
  echo "here: already attached."
  echo "  project   : $PROJ"
  echo "  workspace : $WS   (backlog: $todo todo)"
  echo "  from this directory: loop up | loop run | loop dashboard | loop publish | loop refresh"
  exit 0
fi

if [ ! -d "$PROJ/.git" ]; then
  echo "here: NOTE — $PROJ is not a git repository. canonical will start EMPTY and"
  echo "      publish/refresh (result flow-back) will not be available."
fi

mkdir -p "$LOOP_HOME/workspaces"
if [ -d "$PROJ/.git" ]; then
  "$CONTROL_DIR/init.sh" "$WS" "$PROJ" --name "$(basename "$PROJ")"
else
  "$CONTROL_DIR/init.sh" "$WS" --name "$(basename "$PROJ")"
fi
# Record the binding for publish/refresh/workspaces (informational; resolution is by slug).
echo "PROJECT_PATH=$PROJ" >> "$WS/.loop-workspace"

cat <<EOF

here: attached — the project repo itself was NOT touched (zero footprint).
  project   : $PROJ
  workspace : $WS

Daily flow (all runnable from inside the project):
  1. one-time: cp $WS/secret.env.example $WS/secret.env && chmod 600 ...
               \$EDITOR $WS/skills/VISION.md ARCHITECTURE.md RULES.md
               loop setup                    # builds image, clones canonical from the project
  2. \$EDITOR $WS/memory/backlog.md          # write goals
     loop up                                 # fleet + dashboard; loop pane pre-armed
  3. loop publish                            # landed work -> project branch loop/$BASE_BRANCH
     (in the project) git merge loop/$BASE_BRANCH
  4. loop refresh                            # absorb YOUR new commits into the loop's base
EOF
