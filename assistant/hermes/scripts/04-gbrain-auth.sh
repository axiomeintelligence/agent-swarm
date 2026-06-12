#!/command/with-contenv sh
# 04-gbrain-auth.sh — refresh gbrain OAuth token on every Hermes startup.
#
# Runs as a cont-init.d script (s6-overlay) after 03-mcp-config has registered
# the gbrain MCP server in config.yaml. Uses with-contenv so the Docker container
# environment (GBRAIN_ADMIN_TOKEN) is available.
#
# OAuth flow: client credentials with resource indicator (RFC 8707), required by
# gbrain's OAuth verifier. Access tokens expire after ~3600s; refreshing on every
# Hermes startup ensures a valid token is always present in config.yaml.
#
# Idempotency: runs on EVERY startup (no sentinel). Client credentials are cached
# in .gbrain-client.json to avoid accumulating new OAuth clients on each boot.
set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"
CONFIG="${HERMES_HOME}/config.yaml"

if [ ! -f "${CONFIG}" ]; then
    echo "[hermes-gbrain-auth] ERROR: ${CONFIG} not found" >&2
    exit 1
fi

python3 -u - <<'PYEOF'
import yaml, os, json, http.cookiejar, urllib.parse, time
from urllib.request import urlopen, Request, build_opener, HTTPCookieProcessor
from urllib.error import URLError, HTTPError

hermes_home = os.environ.get("HERMES_HOME", "/opt/data")
config_path = hermes_home + "/config.yaml"

with open(config_path) as f:
    config = yaml.safe_load(f) or {}

key = "mcpServers" if "mcpServers" in config else "mcp_servers" if "mcp_servers" in config else "mcpServers"
servers = config.get(key, {})
dirty = False

gbrain_admin_token = os.environ.get("GBRAIN_ADMIN_TOKEN", "")
GBRAIN_BASE = "http://gbrain:3131"
CREDS_PATH = hermes_home + "/.gbrain-client.json"

if not gbrain_admin_token:
    print("[hermes-gbrain-auth] GBRAIN_ADMIN_TOKEN not set — skipping gbrain auth", flush=True)
elif "gbrain" not in servers:
    print("[hermes-gbrain-auth] gbrain not in MCP servers — skipping gbrain auth", flush=True)
else:
    print(f"[hermes-gbrain-auth] GBRAIN_ADMIN_TOKEN present ({len(gbrain_admin_token)} chars), configuring OAuth", flush=True)

    # gbrain may still be starting — wait up to 30s for it to accept connections.
    # Any HTTP response (even 4xx) means the server is up; only connection errors mean not ready.
    MAX_WAIT = 30
    RETRY_INTERVAL = 3
    deadline = time.time() + MAX_WAIT
    gbrain_ready = False
    while time.time() < deadline:
        try:
            urlopen(Request(f"{GBRAIN_BASE}/", method="GET"), timeout=3)
            gbrain_ready = True
            break
        except HTTPError:
            gbrain_ready = True
            break
        except (URLError, Exception):
            print("[hermes-gbrain-auth] waiting for gbrain to be ready...", flush=True)
            time.sleep(RETRY_INTERVAL)

    if not gbrain_ready:
        print(f"[hermes-gbrain-auth] WARNING: gbrain not reachable after {MAX_WAIT}s — skipping auth", flush=True)
    else:
        try:
            # Reuse existing OAuth client credentials if already registered
            if os.path.exists(CREDS_PATH):
                with open(CREDS_PATH) as f:
                    creds = json.load(f)
                client_id = creds["client_id"]
                client_secret = creds["client_secret"]
                print("[hermes-gbrain-auth] using existing gbrain OAuth client", flush=True)
            else:
                # Register a new confidential OAuth client via admin API (cookie auth)
                jar = http.cookiejar.CookieJar()
                opener = build_opener(HTTPCookieProcessor(jar))
                opener.open(
                    Request(f"{GBRAIN_BASE}/admin/login",
                        data=json.dumps({"token": gbrain_admin_token}).encode(),
                        headers={"Content-Type": "application/json"},
                        method="POST"),
                    timeout=5
                )
                reg_resp = opener.open(
                    Request(f"{GBRAIN_BASE}/admin/api/register-client",
                        data=json.dumps({"name": "hermes", "type": "confidential"}).encode(),
                        headers={"Content-Type": "application/json"},
                        method="POST"),
                    timeout=5
                )
                client = json.loads(reg_resp.read())
                client_id = client["clientId"]
                client_secret = client["clientSecret"]
                with open(CREDS_PATH, "w") as f:
                    json.dump({"client_id": client_id, "client_secret": client_secret}, f)
                os.chmod(CREDS_PATH, 0o600)
                print("[hermes-gbrain-auth] registered new gbrain OAuth client", flush=True)

            # Always get a fresh access token (tokens expire after ~3600s).
            # The resource indicator is required by gbrain's OAuth verifier (RFC 8707).
            token_body = urllib.parse.urlencode({
                "grant_type": "client_credentials",
                "client_id": client_id,
                "client_secret": client_secret,
                "resource": GBRAIN_BASE,
            })
            tok_resp = urlopen(
                Request(f"{GBRAIN_BASE}/token",
                    data=token_body.encode(),
                    headers={"Content-Type": "application/x-www-form-urlencoded"},
                    method="POST"),
                timeout=5
            )
            token_data = json.loads(tok_resp.read())
            access_token = token_data.get("access_token", "")

            if access_token:
                if "headers" not in servers["gbrain"]:
                    servers["gbrain"]["headers"] = {}
                servers["gbrain"]["headers"]["Authorization"] = f"Bearer {access_token}"
                print(f"[hermes-gbrain-auth] gbrain OAuth token refreshed (suffix: ...{access_token[-8:]})", flush=True)
                dirty = True
            else:
                print("[hermes-gbrain-auth] WARNING: gbrain /token returned no access_token", flush=True)

        except (URLError, HTTPError) as e:
            print(f"[hermes-gbrain-auth] WARNING: could not configure gbrain auth: {e}", flush=True)
        except Exception as e:
            print(f"[hermes-gbrain-auth] WARNING: gbrain auth setup failed: {e}", flush=True)

if dirty:
    config[key] = servers
    with open(config_path, "w") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
    print("[hermes-gbrain-auth] config.yaml written", flush=True)
else:
    print("[hermes-gbrain-auth] config.yaml unchanged", flush=True)
PYEOF
