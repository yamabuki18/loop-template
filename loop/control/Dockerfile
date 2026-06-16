FROM node:22-bookworm

# Common dev tooling. jq is required by the harness hooks. Add your project's runtimes here.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ripgrep jq ca-certificates curl less \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI (image ships Node 22, which satisfies Claude Code's Node requirement).
# Pin the version for reproducibility (C2): override via `--build-arg CLAUDE_CODE_VERSION=x.y.z`
# or config.env. Empty = latest. Auto-update is disabled in worker settings so a rebuilt image
# behaves identically until you deliberately bump the pin.
ARG CLAUDE_CODE_VERSION=
RUN if [ -n "$CLAUDE_CODE_VERSION" ]; then \
        npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    else \
        npm install -g @anthropic-ai/claude-code; \
    fi
ENV DISABLE_AUTOUPDATER=1

# The mounted exchange repo is owned by the HOST uid (e.g. 1000), but container users (dev=1001,
# or root in the gate) differ — git then refuses with "dubious ownership" and clone/push fail.
# The container is a trusted, disposable sandbox, so mark all repos safe system-wide for EVERY
# user. Without this, worker-prepare's clone and the gate's clone both die. (system => dev+root)
RUN git config --system --add safe.directory '*'

# Scripts (run as root, world-executable)
COPY worker-prepare                       /usr/local/bin/worker-prepare
COPY worker-harness/harness-session-start /usr/local/bin/harness-session-start
COPY worker-harness/harness-guard-git     /usr/local/bin/harness-guard-git
COPY worker-harness/harness-guard-paths   /usr/local/bin/harness-guard-paths
COPY worker-harness/harness-autopush      /usr/local/bin/harness-autopush
COPY worker-harness/harness-stop-gate     /usr/local/bin/harness-stop-gate
RUN chmod +x /usr/local/bin/worker-prepare \
             /usr/local/bin/harness-session-start \
             /usr/local/bin/harness-guard-git \
             /usr/local/bin/harness-guard-paths \
             /usr/local/bin/harness-autopush \
             /usr/local/bin/harness-stop-gate \
 && (userdel -r node 2>/dev/null || true) \
 && useradd -m -u 1000 -s /bin/bash dev \
 && mkdir -p /home/dev/.claude /work \
 && chown -R dev:dev /home/dev/.claude /work
# WHY uid 1000: the worker user MUST share the host uid so it can WRITE the host-bind-mounted
# exchange repo (worker push, spawn.sh) and the planner's /out dir (plan.sh). node:22-bookworm
# already occupies uid 1000 with its `node` user, which would push `dev` to 1001 and make those
# host-owned mounts read-only to the worker — the planner then can't write slices.json and the
# worker can't push. (If your host uid is not 1000, build with the right id, e.g. add an ARG.)

# Worker "memory" (advisory, L1/L2) + harness hooks (deterministic, absolute)
COPY --chown=dev:dev CLAUDE.worker.md          /home/dev/.claude/CLAUDE.md
COPY --chown=dev:dev worker-harness/settings.json /home/dev/.claude/settings.json
# Pre-seed Claude Code's user config so the worker's INTERACTIVE `claude --dangerously-skip-permissions`
# launches straight to a usable prompt with NO blocking first-run dialogs (otherwise assign.sh's /
# verify.sh's tmux send-keys nudge lands in the theme picker / login / trust / bypass-warning UI and
# the worker never starts). The three gates are: hasCompletedOnboarding (theme + login screens),
# projects["/work"].hasTrustDialogAccepted (folder-trust), bypassPermissionsModeAccepted (the
# --dangerously-skip-permissions warning). NOTE: this is the HOME-level FILE /home/dev/.claude.json,
# NOT a file inside the /home/dev/.claude/ dir (plan.sh overmounts that dir but not this file).
COPY --chown=dev:dev worker-claude.json /home/dev/.claude.json

USER dev
WORKDIR /work

# The container just stays alive; we attach Claude via `docker exec` from a tmux window.
ENTRYPOINT ["sleep", "infinity"]
