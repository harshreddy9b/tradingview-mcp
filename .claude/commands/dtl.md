**MODEL: Use claude-opus-4-7 for this entire analysis.** If you are not currently on Opus 4.7, note this at the top of your response.

Connect to TradingView via CDP (localhost:9222) and run the full day trading levels analysis for the "Custom-Harsha DTL" watchlist.

**Watchlist tickers (13 total):**
QQQ, SPY, IWM, MSFT, NVDA, AAPL, META, AMZN, TSLA, PLTR, COIN, CRCL, MSTR

**Use the Node.js CDP approach directly — do NOT spawn subagents (they can't reach localhost:9222).**

Connect via: `import CDP from './node_modules/chrome-remote-interface/index.js';`

---

## Step 1 — Intraday Levels (all 13 symbols sequentially)

For each symbol:
1. `chart.setSymbol(sym, {})` — wait 2800ms
2. Read last bar OHLC from `window.TradingViewApi._activeChartWidgetWV.value()._chartWidget.model().mainSeries().bars()`
3. Read pine lines from `pc.dwglines?.get('lines')?.get(false)?._primitivesDataById` — "PMH/PML + Yesterday H/L + ORB" draws [PMH, PML, PDH, PDL] in that order
4. Read study values:
   - "VWAP EMA 8/21 Trend Entriesv2" → [VWAP, EMA8, EMA21]
   - "Relative Strength Index" → [RSI, _, RSI_MA]

## Step 2 — 1H Support & Resistance (all 13 symbols sequentially)

For each symbol after intraday levels:
1. `chart.setResolution('60', {})` — wait 2000ms
2. Read last 20 bars of OHLCV
3. Swing highs (bar high > both neighbors) = resistance candidates → sort nearest to price, take top 3 → R1 (nearest), R2, R3
4. Swing lows (bar low < both neighbors) = support candidates → sort nearest to price, take top 3 → S1 (nearest), S2, S3
5. After all symbols: restore original resolution

---

## Output format

### Per-ticker section (all 13):
Brief bias + trade setup (entry, target, stop)

### Master summary table (REQUIRED — include every time):

| Ticker | Price | PMH | PML | PDH | PDL | R3 | R2 | R1 | S1 | S2 | S3 | RSI | Bias |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| QQQ | ... | ... | ... | ... | ... | ... | ... | ... | ... | ... | ... | ... | ... |
(one row per ticker, all 13)

### Personal pick of the day:
Full rationale, entry, target, stop, R:R ratio

---

## Step 3 — Save PDF

After printing the analysis to chat, ALWAYS generate a PDF copy:

1. Write the per-ticker setups to `/tmp/dtl_setups.json` as `{ "QQQ": { "bias": "...", "text": "..." }, ... }` for all 13 tickers.
2. Write the personal pick to `/tmp/dtl_pick.json` with keys: `title`, `why`, `entry`, `stop`, `t1`, `t2`, `rr`, `inv`.
3. Run `node dtl_generate_pdf.mjs "<report-title>" /tmp/dtl_pick.json /tmp/dtl_setups.json [label]`
   - The script reads `/tmp/dtl_step1.json` and `/tmp/dtl_step2.json` (already produced by steps 1 and 2).
   - Filename auto-selected from the current ET hour:
     - 8–10 AM ET → `DTL-YYYY-MM-DD-premarket.pdf`
     - 11 AM–1 PM ET → `DTL-YYYY-MM-DD-midday.pdf`
     - Other hours → `DTL-YYYY-MM-DD.pdf`
   - Pass an optional 5th arg to force a label (e.g. `premarket`, `midday`, `EOD`).
   - Saved to `/Users/harshreddy9/Code/Trading-Ticker Summary/`.
4. Confirm the file path in your final message.

The generator uses headless Google Chrome (`/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`) for PDF rendering — no extra deps needed.

## Step 4 — Email the PDF

After the PDF is generated, ALWAYS email it to `boravelli.sreeharsha@gmail.com`:

```bash
python3 dtl_send_email.py "<pdf_path>" "<report-title>"
```

- Sender + default recipient: `boravelli.sreeharsha@gmail.com`
- Subject: pass the same `<report-title>` you used for the PDF (e.g. `DTL Premarket — 2026-05-19`)
- Reads the Gmail app password from env `GMAIL_APP_PASSWORD` or macOS keychain (service `dtl-gmail-app-password`, account `boravelli.sreeharsha@gmail.com`)
- If the credential is missing, the script prints exact setup instructions — surface them to the user verbatim and stop

Confirm send success in the final message ("Emailed to boravelli.sreeharsha@gmail.com").
