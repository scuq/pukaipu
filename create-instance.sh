#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo ./create-instance.sh <username> --fqdn <fqdn> [--host-port PORT] [--image-tag TAG]
#
# Creates (idempotent):
#   system user <username> (nologin, password locked) with home /home/<username>
#   /opt/pukaipu/<username>/docker-compose.yml
#   /opt/pukaipu/<username>/seccomp_chrome.json (copied from repo config/host if missing)
#   /opt/pukaipu/<username>/seccomp_log.json    (copied from repo config/host if missing)

BASE_DIR="/opt/pukaipu"
DEFAULT_START_PORT=8443

# New users created by this script must be in this UID/GID range:
UID_MIN=3000
UID_MAX=4000

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[pukaipu] $*"; }

need_root() { [[ "${EUID}" -eq 0 ]] || die "run as root (use sudo)"; }

detect_engine() {
  if command -v docker >/dev/null 2>&1; then echo "docker"; return 0; fi
  if command -v podman >/dev/null 2>&1; then echo "podman"; return 0; fi
  die "neither 'docker' nor 'podman' found in PATH"
}

find_free_port() {
  local start="$1"
  local p="$start"
  while true; do
    if command -v ss >/dev/null 2>&1; then
      ss -ltn "( sport = :$p )" | grep -q ":$p" || { echo "$p"; return 0; }
    else
      grep -q ":$(printf '%04X' "$p")" /proc/net/tcp /proc/net/tcp6 2>/dev/null || { echo "$p"; return 0; }
    fi
    p=$((p+1))
    [[ "$p" -lt 65535 ]] || die "no free port found"
  done
}

USERNAME=""
HOST_PORT=""
FQDN=""
IMAGE_TAG=""

validate_fqdn() {
  local f="$1"
  # Simple, strict-enough FQDN check (labels 1..63, no underscores, no trailing dot)
  [[ "$f" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
    || die "invalid fqdn: '$f'"
}

parse_args() {
  [[ $# -ge 1 ]] || die "usage: $0 <username> --fqdn <fqdn> [--host-port PORT] [--image-tag TAG]"
  USERNAME="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host-port)
        shift; [[ $# -gt 0 ]] || die "--host-port requires a value"
        HOST_PORT="$1"; shift
        ;;
      --fqdn)
        shift; [[ $# -gt 0 ]] || die "--fqdn requires a value"
        FQDN="$1"; shift
        ;;
      --image-tag)
        shift; [[ $# -gt 0 ]] || die "--image-tag requires a value"
        IMAGE_TAG="$1"; shift
        ;;
      *)
        die "unknown arg: $1"
        ;;
    esac
  done

  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid username: '$USERNAME'"
  [[ -n "$FQDN" ]] || die "--fqdn is required"
  validate_fqdn "$FQDN"
}

# -------- UID/GID allocation in range 3000-4000 --------

uid_in_use() {
  local uid="$1"
  getent passwd | awk -F: -v u="$uid" '$3==u{found=1} END{exit found?0:1}'
}

gid_in_use() {
  local gid="$1"
  getent group | awk -F: -v g="$gid" '$3==g{found=1} END{exit found?0:1}'
}

find_free_id_in_range() {
  # find_free_id_in_range <min> <max> <type>
  # type: "uid" or "gid"
  local min="$1" max="$2" type="$3"
  local i
  for i in $(seq "$min" "$max"); do
    if [[ "$type" == "uid" ]]; then
      uid_in_use "$i" || { echo "$i"; return 0; }
    else
      gid_in_use "$i" || { echo "$i"; return 0; }
    fi
  done
  return 1
}

ensure_user_with_home() {
  local u="$1"
  local h="/home/$u"

  if id "$u" >/dev/null 2>&1; then
    mkdir -p "$h"
    chown "$u:$u" "$h" 2>/dev/null || true
    chmod 0750 "$h" 2>/dev/null || true
    return 0
  fi

  # Allocate UID in range
  local uid gid
  uid="$(find_free_id_in_range "$UID_MIN" "$UID_MAX" "uid")" \
    || die "no free UID available in range ${UID_MIN}-${UID_MAX}"

  # Prefer GID = UID if free; else allocate another GID in range
  if gid_in_use "$uid"; then
    gid="$(find_free_id_in_range "$UID_MIN" "$UID_MAX" "gid")" \
      || die "no free GID available in range ${UID_MIN}-${UID_MAX}"
  else
    gid="$uid"
  fi

  # Ensure group exists with chosen GID
  if ! getent group "$u" >/dev/null 2>&1; then
    groupadd --gid "$gid" "$u"
  else
    gid="$(getent group "$u" | awk -F: '{print $3}')"
  fi

  # Create user (NO --system) with selected UID/GID
  useradd \
    --uid "$uid" \
    --gid "$gid" \
    --create-home \
    --home-dir "$h" \
    --shell /usr/sbin/nologin \
    "$u"

  passwd -l "$u" >/dev/null 2>&1 || true
  chmod 0750 "$h" 2>/dev/null || true

  log "created user '$u' uid=$uid gid=$gid (range ${UID_MIN}-${UID_MAX})"
}

# -------- file staging / compose generation --------

copy_if_missing() {
  local src="$1"
  local dst="$2"

  [[ -e "$src" ]] || die "missing in repo: $src"

  if [[ -e "$dst" ]]; then
    log "keep (exists): $(basename "$dst")"
    return 0
  fi

  install -m 0644 "$src" "$dst"
  log "copied: $(basename "$dst")"
}

stage_host_seccomp_only() {
  local u="$1"
  local inst_dir="${BASE_DIR}/${u}"
  mkdir -p "$inst_dir"

  copy_if_missing "${SCRIPT_DIR}/config/host/seccomp_chrome.json" "${inst_dir}/seccomp_chrome.json"
  copy_if_missing "${SCRIPT_DIR}/config/host/seccomp_log.json"    "${inst_dir}/seccomp_log.json"
}

write_compose_if_missing() {
  local u="$1"
  local uid="$2"
  local gid="$3"
  local engine="$4"
  local fqdn="$5"

  local inst_dir="${BASE_DIR}/${u}"
  local yml="${inst_dir}/docker-compose.yml"
  local host_home="/home/${u}"

  if [[ -f "$yml" ]]; then
    log "compose exists: $yml (no changes)"
    log "engine detected: $engine"
    return 0
  fi

  if [[ -z "${HOST_PORT}" ]]; then
    HOST_PORT="$(find_free_port "$DEFAULT_START_PORT")"
  fi

  # default tag: YY.MM.DD-HHmm (local time)
  if [[ -z "$IMAGE_TAG" ]]; then
    IMAGE_TAG="$(date '+%y.%m.%d-%H%M')"
  fi
  local image_name="pukaipu:${IMAGE_TAG}"

  [[ -f "${SCRIPT_DIR}/Containerfile" ]] || die "missing Containerfile in repo: ${SCRIPT_DIR}/Containerfile"

  cat > "$yml" <<EOF
services:
  pukaipu-${u}:
    user: "${uid}:${gid}"

    build:
      context: ${SCRIPT_DIR}
      dockerfile: Containerfile

    image: ${image_name}
    container_name: pukaipu-${u}

    ports:
      - "${HOST_PORT}:8443"

    shm_size: "1g"

    cap_drop:
      - ALL

    security_opt:
      - seccomp:./seccomp_chrome.json
      - apparmor:pukaipu

    volumes:
      - ${host_home}:/data/home
      - /opt/pukaipu/${u}/certs:/data/certs

    environment:
      PUKAIPU_USER: "${u}"
      PUKAIPU_FQDN: "${fqdn}"
      HOME: "/data/home"
      BRAVE_URL: "https://example.com"
      BRAVE_ARGS: "--disable-dev-shm-usage --no-first-run --disable-gpu --disable-software-rasterizer --force-dark-mode --enable-features=WebUIDarkMode"

    restart: unless-stopped

    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=128m,mode=1777
EOF

  chmod 0644 "$yml"

  mkdir -p "/opt/pukaipu/${u}/certs"
  chown "${uid}:${gid}" "/opt/pukaipu/${u}/certs" 2>/dev/null || true
  chmod 0700 "/opt/pukaipu/${u}/certs" 2>/dev/null || true

  log "wrote: $yml"
  log "engine detected: $engine"
  log "instance: ${u} uid=${uid} gid=${gid} host-port=${HOST_PORT} -> container 8443"
  log "fqdn: ${fqdn}"
  log "image tag: ${image_name}"
  log "run: cd ${inst_dir} && ${engine} compose up -d --build"
}

main() {
  need_root
  parse_args "$@"

  local engine
  engine="$(detect_engine)"

  ensure_user_with_home "$USERNAME"

  local uid gid
  uid="$(id -u "$USERNAME")"
  gid="$(id -g "$USERNAME")"

  stage_host_seccomp_only "$USERNAME"
  write_compose_if_missing "$USERNAME" "$uid" "$gid" "$engine" "$FQDN"
}

main "$@"
