FROM nousresearch/hermes-agent:latest

# ── System deps for gbrain + skills hot-reload ────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    inotify-tools \
    git \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# ── Bun (required by gbrain) ──────────────────────────────────────────────────
ARG BUN_VERSION=1.1.43
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local BUN_INSTALL_VERSION=${BUN_VERSION} bash

# ── gbrain CLI ────────────────────────────────────────────────────────────────
ARG GBRAIN_REF=main
RUN git clone --depth 1 --branch "${GBRAIN_REF}" https://github.com/garrytan/gbrain /opt/gbrain-src \
    && cd /opt/gbrain-src \
    && bun install \
    && bun link

ENV GBRAIN_HOME=/opt/gbrain-home

# ── cont-init.d scripts ───────────────────────────────────────────────────────
# Run in lexicographic order after 01-hermes-setup seeds config.yaml:
#   03-mcp-config         -- injects MCP server registrations (gbrain stdio + gdrive-mcp sse)
#   05-start-sync-brain   -- backgrounds periodic mono-repo sync loop
#   06-start-skills-watch -- backgrounds inotifywait skills hot-reload

COPY --chmod=755 scripts/init-mcp.sh              /etc/cont-init.d/03-mcp-config
COPY --chmod=755 scripts/05-start-sync-brain.sh   /etc/cont-init.d/05-start-sync-brain
COPY --chmod=755 scripts/06-start-skills-watch.sh /etc/cont-init.d/06-start-skills-watch

# ── Helper scripts in PATH ────────────────────────────────────────────────────
COPY --chmod=755 scripts/sync-brain.sh          /usr/local/bin/sync-brain.sh
COPY --chmod=755 scripts/gbrain-skills-watch.sh /usr/local/bin/gbrain-skills-watch.sh
