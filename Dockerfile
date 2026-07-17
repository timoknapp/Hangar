FROM debian:13-slim

ARG NODE_VERSION=22

# System packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    git \
    tmux \
    jq \
    ca-certificates \
    gnupg \
    openssh-client \
    openssh-server \
    sudo \
    less \
    vim-tiny \
    nginx \
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

# ttyd (web terminal)
ARG TTYD_VERSION=1.7.7
RUN ARCH=$(dpkg --print-architecture) \
  && if [ "$ARCH" = "amd64" ]; then TTYD_ARCH="x86_64"; elif [ "$ARCH" = "arm64" ]; then TTYD_ARCH="aarch64"; fi \
  && wget -q "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}" \
    -O /usr/local/bin/ttyd \
  && chmod +x /usr/local/bin/ttyd

# Create non-root user
RUN useradd -m -s /bin/bash copilot \
  && echo "copilot ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/copilot

# SSH server setup
RUN mkdir -p /run/sshd \
  && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config \
  && sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
  && printf '%s\n' 'PermitRootLogin no' 'KbdInteractiveAuthentication no' >> /etc/ssh/sshd_config \
  && echo 'AllowUsers copilot' >> /etc/ssh/sshd_config

# tmux config (mobile-friendly)
COPY tmux.conf /home/copilot/.tmux.conf
RUN chown copilot:copilot /home/copilot/.tmux.conf

# Shell config
COPY bashrc /home/copilot/.bashrc
RUN chown copilot:copilot /home/copilot/.bashrc

# Nginx config for toolbar injection
COPY nginx.conf /etc/nginx/sites-available/default
COPY toolbar.js /var/www/html/toolbar.js

# Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Auth helper
COPY auth-setup.sh /home/copilot/auth-setup.sh
RUN chmod +x /home/copilot/auth-setup.sh && chown copilot:copilot /home/copilot/auth-setup.sh

# Repo management helper
COPY repo-add.sh /usr/local/bin/repo-add
RUN chmod +x /usr/local/bin/repo-add

EXPOSE 8080 22 4173

ENTRYPOINT ["/entrypoint.sh"]
