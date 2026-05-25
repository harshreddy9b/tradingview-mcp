# DTL Web Publish — Design

**Date:** 2026-05-25
**Status:** Approved for planning

## Goal

After each scheduled DTL run (9:00 AM and 12:00 PM ET, Mon–Fri), automatically publish the generated report to a public Vercel URL. The site is a single page that always shows the latest report. No archive, no login.

## Non-goals

- Historical archive on the web (older reports stay in `~/Code/Trading-Ticker Summary/` and Gmail).
- Mobile-optimized restyle of the report.
- PDF download button on the page.
- Custom domain.
- Any form of access gating.

## Architecture

```
launchd (9 AM + 12 PM ET, Mon–Fri)
  └─ dtl_run_scheduled.sh
       ├─ existing: claude -p "/dtl"   → /tmp/dtl_report.html, PDF, email
       └─ NEW: dtl_publish_web.sh      → copies HTML to web/public/, deploys via Vercel CLI
```

The publish step runs after `/dtl` completes. It is a separate script invoked from `dtl_run_scheduled.sh` so it can be run manually for testing without re-running the full pipeline.

## Components

### 1. `web/` directory (new, committed to repo)

A minimal Vercel static project living at the root of `tradingview-mcp`.

- `web/public/index.html` — the report page.
  - Committed once with a placeholder ("DTL report not yet published") so the first `vercel deploy` works.
  - On each scheduled run, overwritten locally by `dtl_publish_web.sh` with the latest `/tmp/dtl_report.html`.
  - Added to `.gitignore` after the initial placeholder commit. Local overwrites are never committed.
- `web/vercel.json` — Vercel config:
  - `cleanUrls: true`
  - Cache headers on `index.html`: `Cache-Control: public, max-age=0, must-revalidate` so the latest deploy is always what visitors see.
- `web/.vercel/` — created by `vercel link`; gitignored. Holds project ID.

### 2. `dtl_publish_web.sh` (new, repo root)

Bash script. Idempotent, safe to run manually.

Steps:
1. Verify `/tmp/dtl_report.html` exists. If missing, log `[web-publish] no report HTML found — skipping` and exit 0.
2. Verify `~/.vercel-token` exists and is readable. If missing, log `[web-publish] ERROR: missing ~/.vercel-token` and exit 1.
3. Copy `/tmp/dtl_report.html` → `web/public/index.html`.
4. Run `vercel deploy --prod --prebuilt --token "$(cat ~/.vercel-token)" --cwd web` (or equivalent — exact invocation finalized during implementation).
5. Capture deploy URL from `vercel` output, log to `/tmp/dtl-scheduled.log` as `[web-publish] deployed: <url>`.
6. Exit 0 on success. Exit 1 only on missing token; deploy failures are logged but the script still exits 0 so the parent run isn't marked failed.

### 3. `dtl_run_scheduled.sh` (modified)

Add a publish call after the existing `claude -p "/dtl"` invocation succeeds. The publish step's exit code does not affect the parent's exit code — web publishing is best-effort. PDF and email have already succeeded by this point.

Placement: after the existing `log "=== scheduled run end ..."` block, or just before it but with its own log markers.

## Page content

Reuse the existing `/tmp/dtl_report.html` produced by `dtl_generate_pdf.mjs` with no changes. It contains:
- Master summary table (Price / PMH / PML / PDH / PDL / R1–R3 / S1–S3 / RSI / Bias) for all 13 tickers.
- Per-ticker setups grid.
- Personal Pick of the Day box.
- Footer with generated-at timestamp in ET and model identifier.

CSS is styled for landscape Letter print (`@page { size: Letter landscape }`). In a desktop browser this renders cleanly. On phones, the master table will require horizontal scrolling — acceptable per project decision.

## Secrets / one-time setup

The user performs these once, outside any automated script:

1. `npm i -g vercel`
2. `vercel login`
3. `cd web && vercel link` — creates `.vercel/project.json`. Project is created on Vercel as a static site.
4. `vercel tokens create dtl-runner` → save the resulting token to `~/.vercel-token`.
5. `chmod 600 ~/.vercel-token`.

The launchd environment in `dtl_run_scheduled.sh:24` already exports the node bin to PATH, so the global `vercel` binary is reachable.

## Failure modes

| Failure | Behavior |
|---|---|
| `/tmp/dtl_report.html` missing | Publish script no-ops, logs skip reason, exits 0. |
| `~/.vercel-token` missing | Publish script logs ERROR, exits 1. Parent run logs failure but PDF/email have already succeeded. |
| `vercel deploy` fails (network, quota, auth) | Failure logged with stderr tail. Previous deploy remains live. Publish exits 0 so parent isn't marked failed. |
| `cp` fails (disk full, permissions) | Failure logged. Publish exits 0. |

All publish-side log lines use a `[web-publish]` prefix so they're greppable in `/tmp/dtl-scheduled.log`.

## Testing plan

Manual verification (no automated tests for this — it's a 30-line shell script + a static HTML pass-through):

1. Run `bash dtl_publish_web.sh` manually after a normal `/dtl` run. Confirm URL prints, page loads, content matches `/tmp/dtl_report.html`.
2. Delete `/tmp/dtl_report.html` and re-run. Confirm graceful skip.
3. Move `~/.vercel-token` aside and re-run. Confirm ERROR log and exit 1.
4. Trigger `dtl_run_scheduled.sh` end-to-end. Confirm PDF, email, AND web all succeed. Confirm logs.
5. After next scheduled run fires, visit the URL and confirm the new content is what's live (cache headers working).

## Files touched

- **New:** `web/public/index.html`, `web/vercel.json`, `dtl_publish_web.sh`
- **Modified:** `dtl_run_scheduled.sh`, `.gitignore`
- **Unchanged:** `dtl_generate_pdf.mjs`, all Pine, all MCP code

`.gitignore` additions:
```
web/.vercel/
web/public/index.html
!web/public/.gitkeep
```
The placeholder is committed once via `git add -f web/public/index.html` for the initial deploy, then the ignore rule prevents future overwrites from being staged. A `.gitkeep` keeps the directory present.

## Out-of-scope (YAGNI)

Deferred unless explicitly requested later:
- Archive of past reports on the site
- Web-optimized responsive restyle
- PDF download button
- Custom domain (e.g., `dtl.yourdomain.com`)
- Auth or unguessable URL
- Edge function to fetch on demand instead of redeploying
