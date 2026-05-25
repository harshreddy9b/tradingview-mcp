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

if ( cd "$WEB_DIR" && vercel deploy --prod --token "$token" --yes ) \
     >"$deploy_out" 2>"$deploy_err"; then
  url="$(grep -Eo 'https://[^ ]+\.vercel\.app' "$deploy_out" | tail -1)"
  if [ -n "$url" ]; then
    log "deployed: $url"
  else
    log "deploy succeeded but no URL parsed; see $deploy_out"
  fi
else
  log "ERROR: vercel deploy failed — last stderr:"
  tail -10 "$deploy_err" >> "$LOG"
fi

log "end"
exit 0
