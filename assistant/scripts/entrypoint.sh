#!/usr/bin/env bash
set -euo pipefail

# ── 1. Validate AI provider key ───────────────────────────────────────────────
AI_PROVIDER="${AI_PROVIDER:-anthropic}"
case "$AI_PROVIDER" in
  anthropic)
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
      echo "[assistant] ERROR: AI_PROVIDER=anthropic but ANTHROPIC_API_KEY is not set."
      exit 1
    fi
    ;;
  openai)
    if [ -z "${OPENAI_API_KEY:-}" ]; then
      echo "[assistant] ERROR: AI_PROVIDER=openai but OPENAI_API_KEY is not set."
      exit 1
    fi
    ;;
  openrouter)
    if [ -z "${OPENROUTER_API_KEY:-}" ]; then
      echo "[assistant] ERROR: AI_PROVIDER=openrouter but OPENROUTER_API_KEY is not set."
      exit 1
    fi
    ;;
  *)
    echo "[assistant] ERROR: Unknown AI_PROVIDER '${AI_PROVIDER}'. Valid values: anthropic, openai, openrouter."
    exit 1
    ;;
esac
echo "[assistant] AI provider: ${AI_PROVIDER}"

# ── 2. Configure mem0 ─────────────────────────────────────────────────────────
if [ -n "${MEM0_API_KEY:-}" ]; then
  echo "[assistant] mem0: cloud storage"
else
  echo "[assistant] mem0: local storage at /home/assistant/.mem0"
  mkdir -p /home/assistant/.mem0
fi

# ── 3. Map AgentMail credentials to Hermes email env vars ─────────────────────
# AgentMail IMAP: imap.agentmail.to:993 (SSL) — username: inbox email, password: API key
# AgentMail SMTP: smtp.agentmail.to:465 (SSL) — username: agentmail, password: API key
if [ -n "${AGENTMAIL_API_KEY:-}" ] && [ -n "${AGENTMAIL_INBOX_EMAIL:-}" ]; then
  echo "[assistant] Email: AgentMail (${AGENTMAIL_INBOX_EMAIL})"
  export EMAIL_ADDRESS="${AGENTMAIL_INBOX_EMAIL}"
  export EMAIL_PASSWORD="${AGENTMAIL_API_KEY}"
  export EMAIL_IMAP_HOST="imap.agentmail.to"
  export EMAIL_IMAP_PORT="993"
  export EMAIL_SMTP_HOST="smtp.agentmail.to"
  export EMAIL_SMTP_PORT="465"
elif [ -n "${EMAIL_SMTP_HOST:-}" ] && [ -n "${EMAIL_ADDRESS:-}" ]; then
  echo "[assistant] Email: SMTP/IMAP (${EMAIL_SMTP_HOST})"
else
  echo "[assistant] Email: disabled"
fi

# ── 4. Log active platforms ───────────────────────────────────────────────────
PLATFORMS=()
[ -n "${TELEGRAM_BOT_TOKEN:-}" ] && PLATFORMS+=("Telegram")
[ -n "${SLACK_BOT_TOKEN:-}" ]    && PLATFORMS+=("Slack")
[ -n "${EMAIL_ADDRESS:-}" ]      && PLATFORMS+=("Email")

if [ ${#PLATFORMS[@]} -eq 0 ]; then
  echo "[assistant] No messaging platforms configured — CLI only"
  echo "[assistant] Attach a shell: docker exec -it \${HOSTNAME} hermes"
else
  echo "[assistant] Active platforms: ${PLATFORMS[*]}"
fi

# ── 5. Start Cloudflare Tunnel (if token provided) ────────────────────────────
if [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
  echo "[assistant] Starting Cloudflare Tunnel ..."
  cloudflared tunnel run --token "${CLOUDFLARE_TUNNEL_TOKEN}" &
fi

# ── 6. Launch Hermes gateway (foreground) ─────────────────────────────────────
echo "[assistant] Starting Hermes gateway ..."
exec hermes gateway
