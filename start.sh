#!/usr/bin/env bash
set -euo pipefail

export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe

log() { echo "[$(date -Iseconds)] $*"; }

APPUID="$(id -u)"
APPGID="$(id -g)"

# Option A: HOME is the bind-mounted host home inside the container
export HOME="${HOME:-/data/home}"

# Sanity
[[ -d "${HOME}" ]] || { log "ERROR: HOME '${HOME}' does not exist"; exit 1; }
[[ -w "${HOME}" ]] || { log "ERROR: HOME '${HOME}' not writable by uid=${APPUID} gid=${APPGID}"; exit 1; }

# -------------------------------------------------------------------
# 1) Certs
# -------------------------------------------------------------------
[[ -d /data/certs && -w /data/certs ]] || { log "ERROR: /data/certs missing or not writable by uid=${APPUID}"; exit 1; }
/usr/local/bin/cert.sh

# -------------------------------------------------------------------
# 2) Persistent config (Option A: HOME == /data/home, so no symlink)
# -------------------------------------------------------------------
PERSIST_HOME="/data/home"
PERSIST_CONFIG="${PERSIST_HOME}/.config"
DEFAULT_CFG_ROOT="/opt/default-config"

# If /data/home/.config is (accidentally) a symlink, remove it (break loops)
if [[ -L "${PERSIST_CONFIG}" ]]; then
  log "[config] removing bad symlink: ${PERSIST_CONFIG}"
  rm -f "${PERSIST_CONFIG}"
fi

# Ensure it's a real directory
mkdir -p "${PERSIST_CONFIG}/qtile" "${PERSIST_CONFIG}/rofi" "${PERSIST_CONFIG}/kitty"
mkdir -p "${PERSIST_HOME}/brave-profile" "${PERSIST_HOME}/.cache" "${PERSIST_HOME}/.local/share"

# If HOME is NOT the persist home, then link ~/.config -> persist config.
# But when HOME==/data/home, ~/.config already *is* /data/home/.config, so do nothing.
if [[ "${HOME}" != "${PERSIST_HOME}" ]]; then
  # avoid nuking a real dir by accident; only replace non-dir or wrong target
  if [[ -e "${HOME}/.config" && ! -L "${HOME}/.config" && ! -d "${HOME}/.config" ]]; then
    rm -f "${HOME}/.config" || true
  fi
  if [[ -d "${HOME}/.config" && ! -L "${HOME}/.config" ]]; then
    rm -rf "${HOME}/.config" || true
  fi
  if [[ -L "${HOME}/.config" ]]; then
    # if it's a self-loop or points elsewhere, replace it
    rm -f "${HOME}/.config" || true
  fi
  ln -snf "${PERSIST_CONFIG}" "${HOME}/.config"
fi

# Seed defaults only if missing
if [[ -f "${DEFAULT_CFG_ROOT}/qtile/config.py" && ! -s "${PERSIST_CONFIG}/qtile/config.py" ]]; then
  log "[config] seeding qtile config"
  cp -a "${DEFAULT_CFG_ROOT}/qtile/config.py" "${PERSIST_CONFIG}/qtile/config.py"
fi
if [[ -f "${DEFAULT_CFG_ROOT}/rofi/theme.rasi" && ! -s "${PERSIST_CONFIG}/rofi/theme.rasi" ]]; then
  log "[config] seeding rofi theme"
  cp -a "${DEFAULT_CFG_ROOT}/rofi/theme.rasi" "${PERSIST_CONFIG}/rofi/theme.rasi"
fi
if [[ -f "${DEFAULT_CFG_ROOT}/kitty/kitty.conf" && ! -s "${PERSIST_CONFIG}/kitty/kitty.conf" ]]; then
  log "[config] seeding kitty config"
  cp -a "${DEFAULT_CFG_ROOT}/kitty/kitty.conf" "${PERSIST_CONFIG}/kitty/kitty.conf"
fi

# install custom ca certs
/usr/local/bin/add_custom_ca.sh || true

# -------------------------------------------------------------------
# 3) Start Caddy
# -------------------------------------------------------------------
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!
sleep 0.2
kill -0 "$CADDY_PID" 2>/dev/null || { log "[caddy] failed to start"; exit 1; }

# -------------------------------------------------------------------
# 4) Brave profile cleanup + args
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
# 5) Xpra runtime inside writable storage
# -------------------------------------------------------------------
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/data/home/.cache/xdg-runtime-${APPUID}}"
mkdir -p "${XDG_RUNTIME_DIR}/xpra"
chmod 700 "${XDG_RUNTIME_DIR}" "${XDG_RUNTIME_DIR}/xpra" 2>/dev/null || true

export XAUTHORITY="${HOME}/.Xauthority"
touch "${XAUTHORITY}" 2>/dev/null || true
chmod 600 "${XAUTHORITY}" 2>/dev/null || true

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
  --encoding=png \
  --compress=9 \
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
