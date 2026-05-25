# DTL Web Publish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After each scheduled DTL run, auto-publish the existing `/tmp/dtl_report.html` to a single public Vercel page that always shows the latest report.

**Architecture:** A minimal static project at `web/` deployed via the Vercel CLI. A new `dtl_publish_web.sh` script (called from `dtl_run_scheduled.sh` after the existing `/dtl` invocation) copies the report HTML into `web/public/index.html` and runs `vercel deploy --prod --prebuilt`. Best-effort: publish failures do not fail the parent scheduled run.

**Tech Stack:** Bash, Vercel CLI (Node global), static HTML.

**Spec:** `docs/superpowers/specs/2026-05-25-dtl-web-publish-design.md`

---

## File Structure

**New files:**
- `web/public/index.html` — the report page. Committed once with a placeholder, then locally overwritten by every scheduled run.
- `web/public/.gitkeep` — keeps the directory tracked after `index.html` is ignored.
- `web/vercel.json` — static-site config: clean URLs + `no-cache` headers on `index.html`.
- `dtl_publish_web.sh` — bash script that copies the report HTML and runs `vercel deploy`. Idempotent, runnable manually.

**Modified files:**
- `dtl_run_scheduled.sh` — invoke `dtl_publish_web.sh` after the existing `/dtl` step completes.
- `.gitignore` — ignore `web/.vercel/` and `web/public/index.html` (with `!web/public/.gitkeep` exception).

**Unchanged:** `dtl_generate_pdf.mjs`, `dtl_send_email.py`, all Pine, all MCP code.

---

## Task 1: Manual one-time Vercel setup (user actions)

This task is performed by the user once, before any scripts run. The implementation plan documents it so the engineer doesn't try to automate interactive logins.

**Files:** None modified by the engineer in this task.

- [ ] **Step 1: Confirm Vercel CLI is installed globally**

The user runs:

```bash
npm i -g vercel
vercel --version
```

Expected: a version string (e.g., `34.0.0`). If `vercel` isn't found, install it.

- [ ] **Step 2: Confirm the user is logged in to Vercel**

The user runs:

```bash
vercel whoami
```

Expected: a username/email. If "Not logged in", run `vercel login` and complete the browser flow.

- [ ] **Step 3: Create a deploy token**

The user runs:

```bash
vercel tokens create dtl-runner
```

Copy the printed token (only shown once).

- [ ] **Step 4: Save token to `~/.vercel-token` with restrictive permissions**

The user runs (replacing `<TOKEN>` with the value from Step 3):

```bash
printf '%s' '<TOKEN>' > ~/.vercel-token
chmod 600 ~/.vercel-token
ls -l ~/.vercel-token
```

Expected: `-rw-------  1 harshreddy9 ...`. The file should not have a trailing newline (that's why `printf '%s'` and not `echo`).

- [ ] **Step 5: Verify token works**

The user runs:

```bash
vercel teams list --token "$(cat ~/.vercel-token)"
```

Expected: a team listing (no auth error). If it errors with auth, regenerate the token.

---

## Task 2: Scaffold the `web/` static project

**Files:**
- Create: `web/public/index.html`
- Create: `web/public/.gitkeep`
- Create: `web/vercel.json`

- [ ] **Step 1: Create the placeholder `index.html`**

Create `web/public/index.html` with this exact content:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>DTL Report</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; padding: 2rem; color: #1a1a1a; }
    h1 { color: #0d3b66; }
    .meta { color: #555; }
  </style>
</head>
<body>
  <h1>Day Trading Levels</h1>
  <p class="meta">No report has been published yet. The next scheduled run will populate this page.</p>
</body>
</html>
```

- [ ] **Step 2: Create `.gitkeep`**

Create `web/public/.gitkeep` as an empty file:

```bash
touch web/public/.gitkeep
```

- [ ] **Step 3: Create `web/vercel.json`**

Create `web/vercel.json` with this exact content:

```json
{
  "cleanUrls": true,
  "headers": [
    {
      "source": "/index.html",
      "headers": [
        { "key": "Cache-Control", "value": "public, max-age=0, must-revalidate" }
      ]
    },
    {
      "source": "/",
      "headers": [
        { "key": "Cache-Control", "value": "public, max-age=0, must-revalidate" }
      ]
    }
  ]
}
```

- [ ] **Step 4: Verify the files look right**

Run:

```bash
ls -la web/ web/public/
cat web/vercel.json
```

Expected: `web/vercel.json`, `web/public/index.html`, and `web/public/.gitkeep` all exist. `vercel.json` parses (no jq error if you pipe it: `cat web/vercel.json | jq .`).

- [ ] **Step 5: Commit the scaffolding**

```bash
git add web/public/index.html web/public/.gitkeep web/vercel.json
git commit -m "Add web/ static project scaffolding for DTL Vercel deploy"
```

---

## Task 3: Update `.gitignore`

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Read current `.gitignore`**

```bash
cat .gitignore
```

Note the existing contents so the new lines append cleanly.

- [ ] **Step 2: Append the new ignore rules**

Append these lines to `.gitignore` (do not delete existing rules):

```
# DTL web publish — locally-overwritten artifacts
web/.vercel/
web/public/index.html
!web/public/.gitkeep
```

- [ ] **Step 3: Verify the placeholder `index.html` is still tracked**

```bash
git status web/public/
git check-ignore -v web/public/index.html
```

Expected from `git status`: nothing dirty (the file is already committed; the ignore rule only blocks *future* changes).
Expected from `git check-ignore`: a line referencing `.gitignore` and the rule that matches — this is **OK**, because the file is already in the index. Once tracked, future overwrites won't be staged unless `-f` is used.

- [ ] **Step 4: Verify `.gitkeep` is NOT ignored**

```bash
git check-ignore -v web/public/.gitkeep
```

Expected: exit code 1, no output (the `!` rule re-includes it).

- [ ] **Step 5: Commit**

```bash
git add .gitignore
git commit -m "Ignore locally-overwritten web/public/index.html and web/.vercel/"
```

---

## Task 4: One-time `vercel link` for the project (user action)

**Files:** Creates `web/.vercel/project.json` (gitignored).

- [ ] **Step 1: Link the `web/` directory to a new Vercel project**

The user runs from the repo root:

```bash
cd web
vercel link --token "$(cat ~/.vercel-token)"
```

The prompts:
- "Set up `~/Code/tradingview-mcp/web`?" → **Y**
- "Which scope?" → user's personal account
- "Link to existing project?" → **N**
- "What's your project's name?" → `dtl-report` (or accept default)
- "In which directory is your code located?" → `./` (default)

After this, `web/.vercel/project.json` exists. Confirm:

```bash
ls web/.vercel/
cat web/.vercel/project.json
```

Expected: a JSON file with `projectId` and `orgId`.

- [ ] **Step 2: Do an initial test deploy**

From the repo root:

```bash
cd web && vercel deploy --prod --token "$(cat ~/.vercel-token)" --yes
cd ..
```

Expected: a URL printed (e.g., `https://dtl-report-xxx.vercel.app`). Open it in a browser — the placeholder page should load.

**Save this URL** — it's the permanent address for the report.

---

## Task 5: Create `dtl_publish_web.sh`

**Files:**
- Create: `dtl_publish_web.sh`

- [ ] **Step 1: Write the script**

Create `dtl_publish_web.sh` at the repo root with this exact content:

```bash
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x dtl_publish_web.sh
ls -l dtl_publish_web.sh
```

Expected: `-rwxr-xr-x ... dtl_publish_web.sh`.

- [ ] **Step 3: Lint the script with shellcheck (if available)**

```bash
command -v shellcheck >/dev/null && shellcheck dtl_publish_web.sh || echo "shellcheck not installed — skipping"
```

Expected: no warnings, or a "not installed" message. If shellcheck flags real issues, fix them before continuing.

- [ ] **Step 4: Commit**

```bash
git add dtl_publish_web.sh
git commit -m "Add dtl_publish_web.sh — pushes latest report HTML to Vercel"
```

---

## Task 6: Manually test `dtl_publish_web.sh`

**Files:** None modified. This is a verification task.

- [ ] **Step 1: Test the happy path**

Confirm `/tmp/dtl_report.html` exists from a recent `/dtl` run. If it doesn't, run `/dtl` first to generate one. Then:

```bash
./dtl_publish_web.sh
tail -20 /tmp/dtl-scheduled.log
```

Expected: log lines `[web-publish] start`, `[web-publish] copied report HTML (N bytes)`, `[web-publish] deployed: https://...vercel.app`, `[web-publish] end`. Open the URL in a browser — should show today's report.

- [ ] **Step 2: Test the missing-report case**

```bash
mv /tmp/dtl_report.html /tmp/dtl_report.html.bak
./dtl_publish_web.sh
echo "exit code: $?"
tail -5 /tmp/dtl-scheduled.log
mv /tmp/dtl_report.html.bak /tmp/dtl_report.html
```

Expected: exit code 0, log line `[web-publish] no report HTML at /tmp/dtl_report.html — skipping`.

- [ ] **Step 3: Test the missing-token case**

```bash
mv ~/.vercel-token ~/.vercel-token.bak
./dtl_publish_web.sh
echo "exit code: $?"
tail -5 /tmp/dtl-scheduled.log
mv ~/.vercel-token.bak ~/.vercel-token
```

Expected: exit code 1, log line `[web-publish] ERROR: missing or unreadable /Users/harshreddy9/.vercel-token`.

- [ ] **Step 4: Test that the deployed URL serves fresh content**

After Step 1's successful deploy, modify a recognizable detail in `/tmp/dtl_report.html` (e.g., change the title text), re-run `./dtl_publish_web.sh`, then reload the URL. Expected: the new content is visible without a hard refresh (proves the `no-cache` headers are working).

Restore `/tmp/dtl_report.html` from a fresh `/dtl` run if you modified it.

---

## Task 7: Wire `dtl_publish_web.sh` into the scheduled runner

**Files:**
- Modify: `dtl_run_scheduled.sh` (insert publish call after the existing claude invocation)

- [ ] **Step 1: Read the current end of `dtl_run_scheduled.sh`**

Open `dtl_run_scheduled.sh` and locate the section starting at line 105 (`# Trim noisy logs...`) through the final `exit "$rc"`. The publish call goes **between** the existing exit-code logging and the final `log "=== scheduled run end ..."` line.

- [ ] **Step 2: Insert the publish call**

In `dtl_run_scheduled.sh`, find this block (currently lines ~105–113):

```bash
# Trim noisy logs for the daily file.
log "claude exit=$rc, stdout lines=$(wc -l <"$out_file"), stderr lines=$(wc -l <"$err_file")"
if [ "$rc" -ne 0 ]; then
  log "claude FAILED — last stderr:"
  tail -20 "$err_file" >> "$LOG"
fi

log "=== scheduled run end (rc=$rc) ==="
exit "$rc"
```

Replace it with:

```bash
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
```

- [ ] **Step 3: Lint the modified script**

```bash
command -v shellcheck >/dev/null && shellcheck dtl_run_scheduled.sh || echo "shellcheck not installed — skipping"
```

Expected: no new warnings introduced by the change.

- [ ] **Step 4: Commit**

```bash
git add dtl_run_scheduled.sh
git commit -m "Hook dtl_publish_web.sh into scheduled DTL runner (best-effort)"
```

---

## Task 8: End-to-end verification

**Files:** None modified.

- [ ] **Step 1: Run `dtl_run_scheduled.sh` end-to-end manually**

```bash
./dtl_run_scheduled.sh
```

This will take ~3–5 minutes (full DTL run). Watch the log in another terminal:

```bash
tail -f /tmp/dtl-scheduled.log
```

Expected log progression:
1. `=== scheduled run start ===`
2. CDP / TradingView checks
3. `invoking claude -p "/dtl" (headless)`
4. `claude exit=0, stdout lines=...`
5. `[web-publish] start`
6. `[web-publish] copied report HTML (N bytes)`
7. `[web-publish] deployed: https://...vercel.app`
8. `[web-publish] end`
9. `=== scheduled run end (rc=0) ===`

- [ ] **Step 2: Confirm the live URL shows the freshly-generated report**

Open the Vercel URL in a browser. The "Generated …" timestamp in the footer should match the timestamp from this run (within a few seconds).

- [ ] **Step 3: Confirm no regression in PDF and email**

```bash
ls -lt "/Users/harshreddy9/Code/Trading-Ticker Summary/" | head -3
```

Expected: a new PDF with today's date. Also check Gmail for the report email — it should still arrive.

- [ ] **Step 4: Confirm tracked files look right**

```bash
git status
git log --oneline -10
```

Expected: clean working tree (no modified files from the run — the local `web/public/index.html` overwrite is gitignored). Recent commits include the four from Tasks 2, 3, 5, 7.

- [ ] **Step 5: Wait for next scheduled run and re-verify**

The next launchd-triggered run (9 AM or 12 PM ET on a weekday) should publish automatically without intervention. After it fires, refresh the Vercel URL and confirm the timestamp updated. Check `/tmp/dtl-scheduled.log` for the `[web-publish]` lines.

---

## Done criteria

- [ ] Manual `dtl_run_scheduled.sh` invocation results in a live, updated Vercel URL
- [ ] Failure modes (missing report HTML, missing token) handled gracefully per the spec
- [ ] Next scheduled run (without manual trigger) publishes successfully
- [ ] `git status` is clean after a run — no unintended tracked changes
- [ ] PDF generation and Gmail send still work unchanged
