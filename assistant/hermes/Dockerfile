FROM nousresearch/hermes-agent:latest

# Install init-mcp.sh as a cont-init.d script.
#
# The Hermes image uses s6-overlay v3 with the legacy-cont-init compatibility
# service enabled. Scripts under /etc/cont-init.d/ run in lexicographic order
# before user services start:
#   01-hermes-setup       — seeds config.yaml from cli-config.yaml.example
#   015-supervise-perms   — fixes s6 supervise/ ownership
#   02-reconcile-profiles — sets up per-profile s6-rc services
#   03-mcp-config         — injects MCP server registrations (this script)
#
# Using prefix 03- guarantees we run after 01-hermes-setup has seeded
# config.yaml, so we can safely append to it.
COPY --chmod=755 scripts/init-mcp.sh /etc/cont-init.d/03-mcp-config
COPY --chmod=755 scripts/04-gbrain-auth.sh /etc/cont-init.d/04-gbrain-auth
