FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# System deps — curl/git for Hermes install, libsodium/dbus for Signal protocol support
# xz-utils required: Hermes installer downloads Node.js as a .tar.xz archive
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    libsodium-dev \
    dbus-x11 \
    xz-utils \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Cloudflare Tunnel CLI via official Cloudflare apt repo (same method as devbot)
RUN curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null \
    && echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared jammy main' \
      | tee /etc/apt/sources.list.d/cloudflared.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends cloudflared \
    && rm -rf /var/lib/apt/lists/*

# Create non-root assistant user (mirrors devbot's claude user)
RUN useradd -m -s /bin/bash assistant

# Entrypoint installed as root before user switch
COPY --chmod=755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

# Switch to non-root user for Hermes installation
USER assistant
WORKDIR /home/assistant
ENV PATH="/home/assistant/.local/bin:${PATH}"

# Install Hermes Agent — non-interactive, skip setup wizard and browser engine
# Installs code to ~/.hermes/hermes-agent, binary to ~/.local/bin/hermes
# HERMES_REF defaults to main so a simple `docker compose up --build` always pulls latest.
# Pin to a commit SHA for reproducible builds:
#   docker compose build --build-arg HERMES_REF=e2fd462ebe7dfd13663270b6f3dff6360d2ad297
ARG HERMES_REF=main
RUN curl -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_REF}/scripts/install.sh" \
    | bash -s -- --skip-setup --skip-browser

# Install mem0ai into the Hermes Python virtual environment
# Hermes uses uv (not pip) — invoke uv pip with the venv path
# Note: Hermes installer creates the venv at 'venv' (not '.venv')
RUN /home/assistant/.local/bin/uv pip install --quiet \
    --python /home/assistant/.hermes/hermes-agent/venv/bin/python3 \
    mem0ai

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
