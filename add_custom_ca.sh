#!/usr/bin/env bash
set -euo pipefail

# Where users place custom CAs (PEM/CRT). Mounted via /data/home from host.
USER_CA_DIR="${USER_CA_DIR:-/data/home/ca}"

# Debian trust anchors directory
DST_DIR="/usr/local/share/ca-certificates/pukaipu"

log() { echo "[custom-ca] $*"; }

# Need update-ca-certificates
if ! command -v update-ca-certificates >/dev/null 2>&1; then
  log "update-ca-certificates not found (install ca-certificates package)"
  exit 1
fi

# Nothing to do if no dir or empty
if [[ ! -d "$USER_CA_DIR" ]]; then
  log "no user CA dir: $USER_CA_DIR (skipping)"
  exit 0
fi

shopt -s nullglob
candidates=("$USER_CA_DIR"/*.crt "$USER_CA_DIR"/*.pem "$USER_CA_DIR"/*.cer)
shopt -u nullglob

if (( ${#candidates[@]} == 0 )); then
  log "no *.crt/*.pem/*.cer found in $USER_CA_DIR (skipping)"
  exit 0
fi

# Ensure destination exists
mkdir -p "$DST_DIR"

# Copy only when changed (avoid useless updates)
changed=0
for f in "${candidates[@]}"; do
  base="$(basename "$f")"

  # Debian's update-ca-certificates expects .crt, so normalize name
  # (Even if user provides .pem/.cer)
  out="$DST_DIR/${base%.*}.crt"

  if [[ -f "$out" ]] && cmp -s "$f" "$out"; then
    log "unchanged: $base"
    continue
  fi

  # Basic sanity: must contain at least one cert header
  if ! grep -q "BEGIN CERTIFICATE" "$f"; then
    log "skip (no PEM cert found): $base"
    continue
  fi

  install -m 0644 "$f" "$out"
  log "installed: $base -> $(basename "$out")"
  changed=1
done

if (( changed == 0 )); then
  log "no changes (skipping update-ca-certificates)"
  exit 0
fi

log "updating Debian trust store..."
update-ca-certificates
log "done"
