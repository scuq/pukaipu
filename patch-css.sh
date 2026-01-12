#!/usr/bin/env bash
set -euo pipefail

CSS="${1:-/usr/share/xpra/www/css/client.css}"

if [ ! -f "$CSS" ]; then
  echo "[patch-css] ERROR: not found: $CSS" >&2
  exit 1
fi

echo "[patch-css] patching: $CSS"

# Patch the existing blocks in-place where possible
sed -i -E '
/^[[:space:]]*\.windowhead[[:space:]]*\{/,/^[[:space:]]*\}/ {
  s/height:[[:space:]]*[0-9]+px;/height: 0px !important;/
  s/min-height:[[:space:]]*[0-9]+px;/min-height: 0px !important;/
  s/max-height:[[:space:]]*[0-9]+px;/max-height: 0px !important;/
  s/border-bottom:[^;]*;/border-bottom: 0 !important;/
}
/^[[:space:]]*\.windowicon[[:space:]]*\{/,/^[[:space:]]*\}/ {
  s/display:[[:space:]]*inline-block;/display: none !important;/
  s/width:[[:space:]]*[0-9]+px;/width: 0px !important;/
  s/height:[[:space:]]*[0-9]+px;/height: 0px !important;/
}
' "$CSS"

# Append a hard override once (most reliable)
if ! grep -q 'user override: collapse window chrome' "$CSS"; then
  cat >> "$CSS" <<'EOF'

/* user override: collapse window chrome (header + icon + title + buttons) */
.windowhead {
  height: 0px !important;
  min-height: 0px !important;
  max-height: 0px !important;
  padding: 0 !important;
  margin: 0 !important;
  border: 0 !important;
  overflow: hidden !important;
}

/* kill anything that might still render in the header area */
.windowhead *,
.windowtitle,
.windowbuttons,
.windowicon,
.action-icons,
.action-events,
#top_bar {
  display: none !important;
}

/* if something still reserves space, force it to zero */
.windowtitle,
.windowbuttons,
.windowicon,
#top_bar {
  width: 0 !important;
  height: 0 !important;
  padding: 0 !important;
  margin: 0 !important;
  border: 0 !important;
  overflow: hidden !important;
}`

EOF
fi

echo "[patch-css] done"
