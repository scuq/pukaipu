#!/usr/bin/env bash
set -euo pipefail

export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe

log() { echo "[$(date -Iseconds)] $*"; }

APPUSER="appuser"
APPUID="$(id -u)"
APPGID="$(id -g)"

# If you forgot user: 1000:1000, fail loudly (otherwise you'll chase perms forever)
if [ "${APPUID}" != "1000" ]; then
  log "ERROR: must run as uid 1000. Set docker-compose: user: \"1000:1000\""
  exit 1
fi

# -------------------------------------------------------------------
# 1) Certs (writes to /data/certs; must be writable by uid 1000)
# -------------------------------------------------------------------
/usr/local/bin/cert.sh

# -------------------------------------------------------------------
# 2) Persistent HOME config: seed + link (no chown)
# -------------------------------------------------------------------
PERSIST_HOME="/data/home"
PERSIST_CONFIG="${PERSIST_HOME}/.config"
DEFAULT_CFG_ROOT="/opt/default-config"

mkdir -p "${PERSIST_HOME}"
mkdir -p "${PERSIST_CONFIG}/qtile" "${PERSIST_CONFIG}/rofi" "${PERSIST_CONFIG}/kitty"
mkdir -p "${PERSIST_HOME}/brave-profile" "${PERSIST_HOME}/.cache" "${PERSIST_HOME}/.local/share"

# Link /home/appuser/.config -> /data/home/.config (idempotent)
mkdir -p "/home/${APPUSER}"
rm -rf "/home/${APPUSER}/.config" 2>/dev/null || true
ln -snf "${PERSIST_CONFIG}" "/home/${APPUSER}/.config"

# Seed defaults only if missing (no overwrite)
if [ -f "${DEFAULT_CFG_ROOT}/qtile/config.py" ] && [ ! -s "${PERSIST_CONFIG}/qtile/config.py" ]; then
  log "[config] seeding qtile config"
  cp -a "${DEFAULT_CFG_ROOT}/qtile/config.py" "${PERSIST_CONFIG}/qtile/config.py"
fi
if [ -f "${DEFAULT_CFG_ROOT}/rofi/theme.rasi" ] && [ ! -s "${PERSIST_CONFIG}/rofi/theme.rasi" ]; then
  log "[config] seeding rofi theme"
  cp -a "${DEFAULT_CFG_ROOT}/rofi/theme.rasi" "${PERSIST_CONFIG}/rofi/theme.rasi"
fi
if [ -f "${DEFAULT_CFG_ROOT}/kitty/kitty.conf" ] && [ ! -s "${PERSIST_CONFIG}/kitty/kitty.conf" ]; then
  log "[config] seeding kitty config"
  cp -a "${DEFAULT_CFG_ROOT}/kitty/kitty.conf" "${PERSIST_CONFIG}/kitty/kitty.conf"
fi

# -------------------------------------------------------------------
# 3) Start Caddy (same user is fine; port 8443 is unprivileged)
# -------------------------------------------------------------------
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

sleep 0.2
if ! kill -0 "$CADDY_PID" 2>/dev/null; then
  log "[caddy] failed to start"
  exit 1
fi

# -------------------------------------------------------------------
# 4) Brave profile: cleanup singleton locks
# -------------------------------------------------------------------
BRAVE_PROFILE_DIR="${BRAVE_PROFILE_DIR:-/data/home/brave-profile}"
mkdir -p "${BRAVE_PROFILE_DIR}"

rm -f \
  "${BRAVE_PROFILE_DIR}/SingletonLock" \
  "${BRAVE_PROFILE_DIR}/SingletonCookie" \
  "${BRAVE_PROFILE_DIR}/SingletonSocket" \
  "${BRAVE_PROFILE_DIR}/Lock" \
  2>/dev/null || true

export BRAVE_ARGS="${BRAVE_ARGS:-}"
if [[ "${BRAVE_ARGS}" != *"--user-data-dir="* ]]; then
  export BRAVE_ARGS="--user-data-dir=${BRAVE_PROFILE_DIR} ${BRAVE_ARGS}"
fi

# -------------------------------------------------------------------
# 5) Xpra runtime: keep it inside /data/home (writable by uid 1000)
# -------------------------------------------------------------------
export HOME="/home/${APPUSER}"
export XDG_RUNTIME_DIR="/data/home/.cache/xdg-runtime-${APPUID}"
mkdir -p "${XDG_RUNTIME_DIR}/xpra"
chmod 700 "${XDG_RUNTIME_DIR}" "${XDG_RUNTIME_DIR}/xpra" 2>/dev/null || true

# Ensure xpra does not touch /root/.Xauthority
export XAUTHORITY="${HOME}/.Xauthority"
mkdir -p "$(dirname "${XAUTHORITY}")"
touch "${XAUTHORITY}" 2>/dev/null || true
chmod 600 "${XAUTHORITY}" 2>/dev/null || true

# Clean stale X locks
DNUM="${XPRA_DISPLAY#:}"
rm -f "/tmp/.X${DNUM}-lock" "/tmp/.X11-unix/X${DNUM}" 2>/dev/null || true
rm -rf "${HOME}/.xpra" 2>/dev/null || true

exec xpra start-desktop "${XPRA_DISPLAY}" \
  --daemon=no \
  --exit-with-children=yes \
  --socket-dir="${XDG_RUNTIME_DIR}/xpra" \
  --sessions-dir="${XDG_RUNTIME_DIR}/xpra" \
  --ssh-upgrade=no \
  --bind-ws="${XPRA_WS_BIND:-127.0.0.1:14500}" \
  --auth=none \
  --mdns=no \
  --pulseaudio=no \
  --notifications=no \
  --printing=no \
  --webcam=no \
  --headerbar=no \
  --border=auto,0:off \
  --file-transfer=no \
  --clipboard=yes \
  --desktop-fullscreen=yes \
  --desktop-scaling=off \
  --resize-display=yes \
  --pointer=on \
  --keyboard-sync=yes \
  --keyboard-raw=no \
  --html=/usr/share/xpra/www \
  --xvfb="Xvfb +extension GLX +extension Composite -screen 0 3840x2160x24 -nolisten tcp -noreset" \
  --start-child="/opt/qtile/bin/qtile start"
