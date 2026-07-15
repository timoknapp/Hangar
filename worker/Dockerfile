# =============================================================================
# Dockerfile — Squad Worker with TTYD/SSH observability
# Autonomous worker that picks up GitHub issues and implements them through
# full Squad or restricted plain Copilot sessions. Includes ttyd + SSH for monitoring.
# =============================================================================
FROM debian:12-slim AS credential-guard-builder

RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev \
  && rm -rf /var/lib/apt/lists/*
COPY credential-guard.c /tmp/credential-guard.c
COPY credential-guard-preload.c /tmp/credential-guard-preload.c
RUN gcc -O2 -Wall -Wextra -Werror \
  -o /credential-guard /tmp/credential-guard.c \
  && gcc -O2 -Wall -Wextra -Werror -shared -fPIC \
  -o /libcredential-guard.so /tmp/credential-guard-preload.c

FROM debian:12-slim

ARG NODE_VERSION=22

# System packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    ca-certificates \
    gnupg \
    openssl \
    less \
    procps \
    sudo \
    tmux \
    openssh-server \
    nginx \
    vim-tiny \
  && rm -rf /var/lib/apt/lists/*

# Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
  && apt-get install -y nodejs \
  && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
  && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && apt-get update \
  && apt-get install -y gh \
  && rm -rf /var/lib/apt/lists/*

# Copilot CLI + Squad CLI
# Pinned versions used at build time. Override with --build-arg to upgrade.
# The container also self-updates on start when AUTO_UPDATE_CLI=true (opt-in).
ARG COPILOT_CLI_VERSION=1.0.70
ARG SQUAD_CLI_VERSION=0.11.0
ARG CACHE_BUST=1
RUN echo "cache-bust=${CACHE_BUST}" \
  && npm install -g "@github/copilot@${COPILOT_CLI_VERSION}" "@bradygaster/squad-cli@${SQUAD_CLI_VERSION}"

# Prevent same-user shell/subagent/MCP processes from reading the parent
# Copilot credential through /proc/<pid>/environ.
COPY --from=credential-guard-builder /credential-guard /usr/local/bin/credential-guard
COPY --from=credential-guard-builder /libcredential-guard.so /usr/local/lib/libcredential-guard.so

# ttyd (web terminal)
ARG TTYD_VERSION=1.7.7
RUN ARCH=$(dpkg --print-architecture) \
  && if [ "$ARCH" = "amd64" ]; then TTYD_ARCH="x86_64"; elif [ "$ARCH" = "arm64" ]; then TTYD_ARCH="aarch64"; fi \
  && curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}" \
    -o /usr/local/bin/ttyd \
  && chmod +x /usr/local/bin/ttyd

# Separate the trusted publisher loop from untrusted coding/test execution.
# Both users share workspace files through the squad group, but only copilot
# can read the GitHub App key/token and invoke sudo to drop privileges.
RUN groupadd --system squad \
  && useradd -m -s /bin/bash -g squad copilot \
  && useradd -m -s /bin/bash -g squad squad-agent \
  && echo "copilot ALL=(squad-agent) NOPASSWD: /usr/bin/env" > /etc/sudoers.d/copilot \
  && chmod 440 /etc/sudoers.d/copilot \
  && chmod 700 /home/copilot /home/squad-agent

# SSH server setup
RUN mkdir -p /run/sshd \
  && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config \
  && sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
  && echo 'AllowUsers copilot' >> /etc/ssh/sshd_config

# tmux config
COPY tmux.conf /home/copilot/.tmux.conf
RUN chown copilot:squad /home/copilot/.tmux.conf

# Shell config
COPY bashrc /home/copilot/.bashrc
RUN chown copilot:squad /home/copilot/.bashrc

# Nginx config for toolbar injection
COPY nginx.conf /etc/nginx/sites-available/default
COPY toolbar.js /var/www/html/toolbar.js

# Worker scripts
COPY entrypoint.sh /entrypoint.sh
COPY worker-loop.sh /home/copilot/worker-loop.sh
COPY generate-token.sh /home/copilot/generate-token.sh
COPY git-credential-helper.sh /home/copilot/git-credential-helper.sh
COPY runtime-preflight.sh /home/copilot/runtime-preflight.sh
COPY loop-review-rubric.md /home/copilot/loop-review-rubric.md
RUN chmod +x /entrypoint.sh /home/copilot/worker-loop.sh /home/copilot/generate-token.sh /home/copilot/git-credential-helper.sh /home/copilot/runtime-preflight.sh \
  && chown copilot:squad /home/copilot/worker-loop.sh /home/copilot/generate-token.sh /home/copilot/git-credential-helper.sh /home/copilot/runtime-preflight.sh /home/copilot/loop-review-rubric.md \
  && chmod 700 /home/copilot/worker-loop.sh /home/copilot/generate-token.sh /home/copilot/git-credential-helper.sh /home/copilot/runtime-preflight.sh \
  && chmod 600 /home/copilot/loop-review-rubric.md

EXPOSE 8080 22

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
