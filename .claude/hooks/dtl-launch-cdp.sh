#!/usr/bin/env bash
# Hook: on /dtl, ensure TradingView Desktop is running with CDP (--remote-debugging-port=9222).
# If the port is unreachable, launch TradingView with the debug flag and wait for CDP to come up.
# UserPromptSubmit only — fires once per /dtl invocation, fast no-op when CDP already live.

set -euo pipefail

CDP_URL="http://localhost:9222/json/version"
LOG="/tmp/dtl-launch-cdp.log"

INPUT="$(cat)"
PROMPT="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("prompt",""))' 2>/dev/null || true)"

# Only act when the prompt actually starts the /dtl flow.
printf '%s' "$PROMPT" | grep -qE '(^|[[:space:]])/dtl(\b|$)' || exit 0

# Fast path: CDP already reachable — do nothing.
if curl -s -m 2 "$CDP_URL" >/dev/null 2>&1; then
  printf '[%s] CDP already live, skipping launch\n' "$(date '+%F %T')" >> "$LOG"
  exit 0
fi

printf '[%s] CDP unreachable, launching TradingView with --remote-debugging-port=9222\n' \
  "$(date '+%F %T')" >> "$LOG"

# Kill any non-debug TradingView (silently — may not be running).
killall TradingView >/dev/null 2>&1 || true
sleep 2

# Launch fresh with the CDP flag.
open -a TradingView --args --remote-debugging-port=9222

# Poll until CDP responds (max ~30s) so the first downstream CDP call doesn't race the launch.
for i in $(seq 1 30); do
  if curl -s -m 2 "$CDP_URL" >/dev/null 2>&1; then
    printf '[%s] CDP live after %ds\n' "$(date '+%F %T')" "$i" >> "$LOG"
    exit 0
  fi
  sleep 1
done

printf '[%s] CDP did NOT come up within 30s — /dtl will likely fail to connect\n' \
  "$(date '+%F %T')" >> "$LOG"
exit 0
