FROM node:22-slim

# Install curl for health checks.
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# Install the Google Drive MCP server and supergateway bridge globally.
# @modelcontextprotocol/server-gdrive is stdio-only; supergateway wraps it
# in an HTTP/SSE transport so Hermes can connect via url:.
RUN npm install -g \
    @modelcontextprotocol/server-gdrive \
    supergateway

# supergateway SSE bridge listens on port 3000
EXPOSE 3000

# Health endpoint provided by supergateway --healthEndpoint flag
HEALTHCHECK --interval=10s --timeout=5s --start-period=15s --retries=5 \
  CMD curl -sf http://localhost:3000/healthz || exit 1

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
