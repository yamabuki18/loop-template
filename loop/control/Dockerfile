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
 && useradd -m -s /bin/bash dev \
 && mkdir -p /home/dev/.claude /work \
 && chown -R dev:dev /home/dev/.claude /work

# Worker "memory" (advisory, L1/L2) + harness hooks (deterministic, absolute)
COPY --chown=dev:dev CLAUDE.worker.md          /home/dev/.claude/CLAUDE.md
COPY --chown=dev:dev worker-harness/settings.json /home/dev/.claude/settings.json

USER dev
WORKDIR /work

# The container just stays alive; we attach Claude via `docker exec` from a tmux window.
ENTRYPOINT ["sleep", "infinity"]
