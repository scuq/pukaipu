FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
ENV BRAVE_ARGS="--disable-dev-shm-usage --no-first-run --disable-gpu --disable-software-rasterizer --disable-features=Translate"
ARG XPRA_HTML5_VER=19
ARG QTILE_VER=0.24.0
ARG QTILE_VENV=/opt/qtile

# Base system + tools
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg \
      caddy openssl tini \
      xauth dbus-x11 libx264-164 \
      fonts-dejavu fonts-liberation \
      python3-websockify \
    && rm -rf /var/lib/apt/lists/*

# --- Qtile (bookworm: install via venv) + launcher + terminal ---
RUN apt-get update && apt-get install -y --no-install-recommends \
      rofi xterm \
      python3 python3-venv python3-pip \
      python3-xcffib python3-cairocffi python3-cffi \
      libffi8 \
    && rm -rf /var/lib/apt/lists/*

# --- Optional build-time CA injection (local files, gitignored) ---
# Ensure config/build-ca exists in repo (tracked via .keep), but certs are ignored by git.
COPY config/build-ca/ /usr/local/share/ca-certificates/pukaipu-build/
RUN set -eu; \
    if find /usr/local/share/ca-certificates/pukaipu-build -maxdepth 1 -type f -name '*.crt' | grep -q .; then \
        update-ca-certificates; \
        echo "[build-ca] installed custom build CAs"; \
    else \
        echo "[build-ca] no custom build CAs found, skipping"; \
    fi

# Install Qtile into a dedicated venv (pinned)
RUN set -eux; \
    python3 -m venv "${QTILE_VENV}"; \
    "${QTILE_VENV}/bin/pip" install --no-cache-dir --upgrade pip setuptools wheel; \
    "${QTILE_VENV}/bin/pip" install --no-cache-dir "qtile==${QTILE_VER}"

# ------------------------------------------------------------
# Xpra upstream repository (STABLE) for Debian Bookworm
# ------------------------------------------------------------
RUN set -eux; \
    wget -O /usr/share/keyrings/xpra.asc https://xpra.org/xpra.asc; \
    chmod 644 /usr/share/keyrings/xpra.asc; \
    wget -O /etc/apt/sources.list.d/xpra.sources \
      https://raw.githubusercontent.com/Xpra-org/xpra/master/packaging/repos/bookworm/xpra.sources; \
    apt-get update; \
    apt-get install -y --no-install-recommends xpra xpra-x11; \
    rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------
# Xpra HTML5 client (pinned)
# ------------------------------------------------------------
RUN set -eux; \
    mkdir -p /usr/share/xpra/www; \
    curl -fsSL "https://github.com/Xpra-org/xpra-html5/archive/refs/tags/v${XPRA_HTML5_VER}.tar.gz" \
      | tar -xz --strip-components=2 -C /usr/share/xpra/www "xpra-html5-${XPRA_HTML5_VER}/html5"

# Hot-patch xpra-html5 CSS: shrink the window header bar
COPY patch-css.sh /usr/local/bin/patch-css.sh
RUN chmod +x /usr/local/bin/patch-css.sh

# Run the patch after html5 files exist
RUN /usr/local/bin/patch-css.sh /usr/share/xpra/www/css/client.css

# ------------------------------------------------------------
# Brave browser (official repo)
# ------------------------------------------------------------
RUN set -eux; \
    curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
      https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg; \
    curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources \
      https://brave-browser-apt-release.s3.brave.com/brave-browser.sources; \
    apt-get update; \
    apt-get install -y --no-install-recommends brave-browser; \
    rm -rf /var/lib/apt/lists/*

# X socket dir
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# Non-root user
RUN useradd -m -u 1000 -s /bin/bash appuser

# Store default configs in the image (used for first-run seeding)
RUN mkdir -p /opt/default-config/qtile /opt/default-config/rofi
COPY config/container/qtile-config.py /opt/default-config/qtile/config.py
COPY config/container/rofi-cyber.rasi /opt/default-config/rofi/theme.rasi

# --- Kitty default config ---
RUN mkdir -p /opt/default-config/kitty
COPY config/container/kitty.conf /opt/default-config/kitty/kitty.conf

# --- Qtile + launcher + terminal (kitty) ---
RUN apt-get update && apt-get install -y --no-install-recommends \
      rofi kitty \
      # software OpenGL stack for kitty in Xvfb
      libgl1-mesa-dri libgl1 mesa-utils \
      # useful fonts (kitty looks better with these)
      fonts-dejavu fonts-liberation fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

## --- Qtile config for appuser ---
#COPY qtile-config.py /home/appuser/.config/qtile/config.py
#RUN chown -R appuser:appuser /home/appuser/.config

#RUN mkdir -p /home/appuser/.config/rofi
#COPY rofi-cyber.rasi /home/appuser/.config/rofi/theme.rasi
#RUN chown -R appuser:appuser /home/appuser/.config/rofi

# TLS material persisted here
# Persistent home area (configs, rofi, qtile, etc.)
VOLUME ["/data/home", "/data/certs"]

# Create persistent dirs and link ~/.config -> /data/home/.config
RUN set -eux; \
    mkdir -p /data/home/.config/qtile /data/home/.config/rofi; \
    chown -R appuser:appuser /data/home; \
    rm -rf /home/appuser/.config; \
    ln -s /data/home/.config /home/appuser/.config; \
    chown -h appuser:appuser /home/appuser/.config


# Config + entrypoint
COPY cert.sh /usr/local/bin/cert.sh
RUN chmod +x /usr/local/bin/cert.sh
COPY add_custom_ca.sh /usr/local/bin/add_custom_ca.sh
RUN chmod +x /usr/local/bin/add_custom_ca.sh
COPY Caddyfile /etc/caddy/Caddyfile
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

ENV XPRA_DISPLAY=:100
ENV XPRA_WS_BIND=127.0.0.1:14500
ENV BRAVE_URL="https://example.com"
ENV BRAVE_ARGS="--disable-dev-shm-usage --no-first-run --disable-features=Translate"

EXPOSE 8443

ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["/usr/local/bin/start.sh"]
