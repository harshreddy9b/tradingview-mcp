#!/usr/bin/env bash
# Scheduled DTL runner — invoked by launchd at 9:00 AM and 12:00 PM ET on weekdays.
#
# Steps:
#   1. Skip if today is a US market holiday or weekend (defense-in-depth — launchd
#      already restricts to weekdays).
#   2. Ensure TradingView Desktop is running with CDP on port 9222
#      (kill stale instances, relaunch with --remote-debugging-port=9222, poll).
#   3. Invoke `claude -p "/dtl" --dangerously-skip-permissions` headlessly from the
#      project dir so the slash command runs unattended. The /dtl skill produces
#      the PDF and emails it. The auto-approve hook in this project also fires for
#      /dtl, but the explicit flag is belt-and-suspenders for the headless context.
#
# All output (stdout, stderr, status lines) is appended to /tmp/dtl-scheduled.log.

set -uo pipefail

PROJECT_DIR="/Users/harshreddy9/Code/tradingview-mcp"
HOLIDAY_FILE="${PROJECT_DIR}/dtl_market_holidays.txt"
LOG="/tmp/dtl-scheduled.log"
CDP_URL="http://localhost:9222/json/version"

# launchd starts with an empty PATH. Hardcode what /dtl needs.
export PATH="/opt/homebrew/bin:/Users/harshreddy9/.nvm/versions/node/v24.13.1/bin:/Users/harshreddy9/anaconda3/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

log() { printf '[%s] %s\n' "$(date '+%F %T %Z')" "$*" >> "$LOG"; }

log "=== scheduled run start ==="

# --- Holiday / weekend gate -----------------------------------------------------
today_et="$(TZ=America/New_York date '+%Y-%m-%d')"
dow_et="$(TZ=America/New_York date '+%u')"  # 1=Mon..7=Sun
if [ "$dow_et" -ge 6 ]; then
  log "weekend ($today_et, dow=$dow_et) — skip"
  exit 0
fi
if [ -f "$HOLIDAY_FILE" ] && grep -qE "^${today_et}$" "$HOLIDAY_FILE"; then
  log "market holiday ($today_et) — skip"
  exit 0
fi

# --- TradingView + CDP prerequisite --------------------------------------------
if curl -s -m 3 "$CDP_URL" >/dev/null 2>&1; then
  log "CDP already live on 9222"
else
  log "CDP not reachable — relaunching TradingView with --remote-debugging-port=9222"
  killall TradingView >/dev/null 2>&1 || true
  sleep 2
  /usr/bin/open -a TradingView --args --remote-debugging-port=9222
  cdp_up=0
  for i in $(seq 1 30); do
    if curl -s -m 2 "$CDP_URL" >/dev/null 2>&1; then
      log "CDP live after ${i}s"
      cdp_up=1
      break
    fi
    sleep 1
  done
  if [ "$cdp_up" -ne 1 ]; then
    log "CDP did NOT come up within 30s — abort"
    exit 1
  fi
  # Extra settle so chart + studies finish first paint before /dtl starts reading.
  sleep 8
fi

# --- Run /dtl headlessly --------------------------------------------------------
cd "$PROJECT_DIR" || { log "cd $PROJECT_DIR failed"; exit 1; }

log "invoking claude -p \"/dtl\" (headless)"
# Capture stdout to log; stderr separately. Long timeout — full run takes 3-5 min.
out_file="/tmp/dtl-scheduled-claude.out"
err_file="/tmp/dtl-scheduled-claude.err"
: > "$out_file"; : > "$err_file"

# Hard 8-minute wall-clock cap. macOS has no `timeout` binary, so we fork a
# watchdog. claude -p has been observed to hang after producing the PDF and
# sending the email; the watchdog SIGTERMs it (then SIGKILLs) so launchd
# doesn't leave a stale wrapper running into the next interval.
# --no-session-persistence: don't save a resumable session to disk.
/opt/homebrew/bin/claude -p "/dtl" \
  --dangerously-skip-permissions \
  --no-session-persistence \
  </dev/null >"$out_file" 2>"$err_file" &
claude_pid=$!

( sleep 480
  if kill -0 "$claude_pid" 2>/dev/null; then
    log "claude still alive after 480s — SIGTERM"
    kill -TERM "$claude_pid" 2>/dev/null
    sleep 10
    if kill -0 "$claude_pid" 2>/dev/null; then
      log "claude still alive after SIGTERM — SIGKILL"
      kill -KILL "$claude_pid" 2>/dev/null
    fi
  fi
) &
watchdog_pid=$!

wait "$claude_pid"
rc=$?
kill "$watchdog_pid" 2>/dev/null
wait "$watchdog_pid" 2>/dev/null

# Trim noisy logs for the daily file.
log "claude exit=$rc, stdout lines=$(wc -l <"$out_file"), stderr lines=$(wc -l <"$err_file")"
if [ "$rc" -ne 0 ]; then
  log "claude FAILED — last stderr:"
  tail -20 "$err_file" >> "$LOG"
fi

# --- Web publish (best-effort) -------------------------------------------------
# Push the latest report HTML to Vercel. Failures are logged but do not affect
# the parent run's exit code — PDF and email have already succeeded by here.
if [ "$rc" -eq 0 ]; then
  "${PROJECT_DIR}/dtl_publish_web.sh" || log "web publish exited non-zero (ignored)"
else
  log "skipping web publish because claude run failed"
fi

log "=== scheduled run end (rc=$rc) ==="
exit "$rc"
