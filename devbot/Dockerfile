FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    NODE_OPTIONS=--max-old-space-size=4096

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    gnupg \
    ca-certificates \
    software-properties-common \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Chromium via xtradeb PPA (Ubuntu apt chromium-browser is a snap stub)
# Symlink chromium-browser -> chromium to satisfy acceptance criteria
RUN add-apt-repository -y ppa:xtradeb/apps \
    && apt-get update \
    && apt-get install -y --no-install-recommends chromium \
    && ln -sf /usr/bin/chromium /usr/local/bin/chromium-browser \
    && rm -rf /var/lib/apt/lists/*

# Node 20 LTS via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# claudecodeui — public repo, no auth needed
RUN git clone --depth 1 https://github.com/axiomeintelligence/claudecodeui /opt/claudecodeui \
    && cd /opt/claudecodeui \
    && npm ci

# Create claude user with owned workspace and claudecodeui
RUN useradd -m -s /bin/bash claude \
    && mkdir -p /workspace \
    && chown -R claude:claude /workspace /opt/claudecodeui

# Entrypoint
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER claude
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
