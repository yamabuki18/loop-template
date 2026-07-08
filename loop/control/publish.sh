#!/usr/bin/env bash
# Deliver the loop's landed work back to the project repo WITHOUT touching its working tree:
# push canonical's BASE_BRANCH to the project (canonical's clone origin) as the loop-owned
# branch `loop/<BASE_BRANCH>` (override: PUBLISH_BRANCH in config.env). Forced by design —
# only the loop ever writes that branch; each publish is a full snapshot of the landed state.
#
#   ./control/publish.sh          # then, in the project:  git merge loop/<base>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[ -d "$CANONICAL/.git" ] || die "no canonical yet — run setup first."
dest="$(git -C "$CANONICAL" remote get-url origin 2>/dev/null || true)"
[ -n "$dest" ] || die "canonical has no 'origin' (it was created empty, not from a project repo) — nothing to publish to. Attach with 'loop here' from inside a git project."

PUB="${PUBLISH_BRANCH:-loop/$BASE_BRANCH}"
# Push to the FETCH url explicitly, NOT the `origin` remote: setup.sh blanks origin's push url
# with an unroutable sentinel so workers can't push to the operator's real repo (D12). `$dest`
# above is that fetch url (`remote get-url origin`), so this sanctioned host-side publish works.
git -C "$CANONICAL" push -f "$dest" "refs/heads/$BASE_BRANCH:refs/heads/$PUB"

echo "publish: $BASE_BRANCH -> $dest  (branch: $PUB)"
echo "in the project repo:"
echo "  review : git log -p ..$PUB"
echo "  take   : git merge $PUB"
progress_log PUBLISHED "-" "$BASE_BRANCH" "-> $dest ($PUB)"
notify "published to $PUB"
