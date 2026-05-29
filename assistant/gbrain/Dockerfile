FROM oven/bun:1

ARG GBRAIN_REF=main

# Install ca-certificates, git, and curl.
# ca-certificates: required for HTTPS git clones in slim Debian images.
# git: needed to clone G-Brain at a specific ref.
# curl: needed for the HEALTHCHECK command.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

# Clone G-Brain at the requested ref and install via bun link.
# GBRAIN_REF may be a branch name, tag, or full commit SHA.
# The repo's default branch is 'master'; 'main' is resolved to 'master'
# as a convenience alias so the conventional --build-arg GBRAIN_REF=main works.
RUN set -e; \
    REF="${GBRAIN_REF}"; \
    if [ "$REF" = "main" ]; then REF="master"; fi; \
    git clone --depth 1 --branch "$REF" \
        https://github.com/garrytan/gbrain.git /opt/gbrain; \
    cd /opt/gbrain && bun install && bun link

# GBRAIN_HOME is the *parent* directory; gbrain appends '.gbrain' itself.
# Setting GBRAIN_HOME=/data means config lives at /data/.gbrain/
VOLUME ["/data"]
ENV GBRAIN_HOME=/data

# G-Brain HTTP MCP server listens on port 3131 by default
EXPOSE 3131

# Health check against the /health endpoint
# start-period is generous to allow PGLite WASM init on first boot
HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=6 \
  CMD curl -sf http://localhost:3131/health || exit 1

# Entrypoint: auto-init PGLite brain on first run (idempotent).
# gbrain init --pglite --no-embedding --non-interactive creates the schema if
# no config exists, then hands off to gbrain serve --http.
# --bind 0.0.0.0 is required so the server listens on all container interfaces
# (default is 127.0.0.1 loopback, unreachable from outside the container).
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["gbrain", "serve", "--http", "--bind", "0.0.0.0", "--port", "3131"]
