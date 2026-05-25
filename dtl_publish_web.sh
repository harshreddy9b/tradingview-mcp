#!/usr/bin/env bash
# Publish the latest DTL report HTML to Vercel.
#
# Invoked from dtl_run_scheduled.sh after `/dtl` has produced the PDF + HTML.
# Safe to run manually for testing.
#
# Inputs:
#   /tmp/dtl_report.html  — produced by dtl_generate_pdf.mjs
#   ~/.vercel-token       — Vercel deploy token (chmod 600)
#
# Best-effort: deploy failures are logged but the script exits 0 so the
# parent scheduled run isn't marked as failed (PDF + email have already
# succeeded by the time this runs).

set -uo pipefail

PROJECT_DIR="/Users/harshreddy9/Code/tradingview-mcp"
WEB_DIR="${PROJECT_DIR}/web"
REPORT_HTML="/tmp/dtl_report.html"
TOKEN_FILE="${HOME}/.vercel-token"
LOG="/tmp/dtl-scheduled.log"

# launchd starts with an empty PATH. Hardcode what `vercel` needs.
export PATH="/opt/homebrew/bin:/Users/harshreddy9/.nvm/versions/node/v24.13.1/bin:/usr/local/bin:/usr/bin:/bin"

log() { printf '[%s] [web-publish] %s\n' "$(date '+%F %T %Z')" "$*" >> "$LOG"; }

log "start"

# --- Preflight checks -----------------------------------------------------------
if [ ! -f "$REPORT_HTML" ]; then
  log "no report HTML at $REPORT_HTML — skipping"
  exit 0
fi

if [ ! -r "$TOKEN_FILE" ]; then
  log "ERROR: missing or unreadable $TOKEN_FILE"
  exit 1
fi

if ! command -v vercel >/dev/null 2>&1; then
  log "ERROR: vercel CLI not on PATH"
  exit 1
fi

# --- Copy HTML into the web project --------------------------------------------
if ! cp "$REPORT_HTML" "${WEB_DIR}/public/index.html"; then
  log "ERROR: failed to copy $REPORT_HTML -> ${WEB_DIR}/public/index.html"
  exit 0  # best-effort
fi
log "copied report HTML ($(wc -c <"$REPORT_HTML") bytes)"

# --- Deploy --------------------------------------------------------------------
deploy_out="/tmp/dtl-vercel-deploy.out"
deploy_err="/tmp/dtl-vercel-deploy.err"
: > "$deploy_out"; : > "$deploy_err"

token="$(cat "$TOKEN_FILE")"

# 120s watchdog. macOS has no `timeout` binary, so fork one inline. Without
# this, a stalled deploy (network/TLS) could block the parent runner long
# enough for launchd to skip the next scheduled slot.
( cd "$WEB_DIR" && VERCEL_TOKEN="$token" vercel deploy --prod --yes ) \
  >"$deploy_out" 2>"$deploy_err" &
deploy_pid=$!

( sleep 120
  if kill -0 "$deploy_pid" 2>/dev/null; then
    kill -TERM "$deploy_pid" 2>/dev/null
    sleep 5
    kill -KILL "$deploy_pid" 2>/dev/null
  fi
) &
watchdog_pid=$!

wait "$deploy_pid"
deploy_rc=$?
kill "$watchdog_pid" 2>/dev/null
wait "$watchdog_pid" 2>/dev/null

if [ "$deploy_rc" -eq 0 ]; then
  # URL regex matches default *.vercel.app; if a custom domain is added later,
  # the URL won't be parsed and the "no URL parsed" branch will fire.
  url="$(grep -Eo 'https://[^ ]+\.vercel\.app' "$deploy_out" | tail -1)"
  if [ -n "$url" ]; then
    log "deployed: $url"
  else
    log "deploy succeeded but no URL parsed; see $deploy_out"
  fi
elif [ "$deploy_rc" -eq 143 ] || [ "$deploy_rc" -eq 137 ]; then
  log "ERROR: vercel deploy killed by 120s watchdog (rc=$deploy_rc)"
else
  log "ERROR: vercel deploy failed (rc=$deploy_rc) — last stderr:"
  tail -10 "$deploy_err" >> "$LOG"
fi

log "end"
exit 0
