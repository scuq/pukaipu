#!/usr/bin/env bash
set -euo pipefail

PROFILE_NAME="pukaipu"
DST="/etc/apparmor.d/${PROFILE_NAME}"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root (use sudo)" >&2
    exit 1
  fi
}

need_tools() {
  command -v apparmor_parser >/dev/null 2>&1 || {
    echo "ERROR: apparmor_parser not found. Install with:" >&2
    echo "  sudo apt install apparmor apparmor-utils" >&2
    exit 1
  }
}

backup_if_exists() {
  if [[ -f "${DST}" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "${DST}" "${DST}.bak.${ts}"
    echo "[info] existing profile backed up to: ${DST}.bak.${ts}"
  fi
}

write_profile() {
  cat > "${DST}" <<'EOF'
#include <tunables/global>

profile pukaipu flags=(attach_disconnected,mediate_deleted) {

  # Base abstractions (optional but commonly present)
  #include <abstractions/base>

  # ---- REQUIRED: Brave / Chromium sandbox ----
  userns,

  # ---- baseline container permissions ----
  network,
  capability,
  file,
  umount,

  # ---- proc hardening ----
  @{PROC}/** r,
  deny @{PROC}/sys/** wklx,
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/kcore rwklx,

  # ---- sysfs hardening ----
  @{sys}/** r,
  deny @{sys}/** wklx,

  # ---- devices needed by Xpra / Xvfb ----
  /dev/null rw,
  /dev/zero rw,
  /dev/full rw,
  /dev/random r,
  /dev/urandom r,
  /dev/tty rw,
  /dev/pts/* rw,
  /dev/shm/** rwk,
  /dev/fuse rw,

  # ---- runtime / tmp ----
  /tmp/** rwk,
  /run/** rwk,

  # ---- broad filesystem access without global execute ----
  /** r,
  /** wkl,

  # ---- allow executing binaries (inherit mode) ----
  /bin/** ix,
  /usr/bin/** ix,
  /usr/sbin/** ix,
  /usr/local/bin/** ix,
  /usr/local/sbin/** ix,
  /opt/** ix,
}
EOF
  echo "[ok] profile written: ${DST}"
}

load_profile() {
  apparmor_parser -r "${DST}"
  echo "[ok] profile loaded: ${PROFILE_NAME}"
}

show_compose_snippet() {
  cat <<EOF

Use this in docker-compose.yml:

services:
  xpra:
    security_opt:
      - apparmor:${PROFILE_NAME}

EOF
}

need_root
need_tools
backup_if_exists
write_profile
load_profile
show_compose_snippet
