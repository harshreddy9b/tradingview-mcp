import CDP from './node_modules/chrome-remote-interface/index.js';

const SYMBOLS = ['QQQ','SPY','IWM','MSFT','NVDA','AAPL','META','AMZN','TSLA','PLTR','COIN','CRCL','MSTR'];

const targets = await CDP.List({ host: 'localhost', port: 9222 });
const tvTarget = targets.find(t => t.url && t.url.includes('tradingview.com') && t.type === 'page');
if (!tvTarget) { console.error('No TradingView tab found'); process.exit(1); }

const c = await CDP({ target: tvTarget.webSocketDebuggerUrl });
const { Runtime } = c;
await Runtime.enable();

async function evalExpr(expr, timeout = 8000) {
  const r = await Runtime.evaluate({ expression: expr, returnByValue: true, awaitPromise: true, timeout });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || JSON.stringify(r.exceptionDetails));
  return r.result?.value;
}

const CHART = 'window.TradingViewApi._activeChartWidgetWV.value()';

const origSym = await evalExpr(`${CHART}._chartWidget.model().mainSeries().symbol()`);
const origRes = await evalExpr(`${CHART}._chartWidget.model().mainSeries().interval()`);
console.error(`Original: ${origSym} @ ${origRes}`);

async function setSymbol(sym) {
  await evalExpr(`${CHART}.setSymbol(${JSON.stringify(sym)}, {})`);
}

async function setRes(res) {
  await evalExpr(`${CHART}.setResolution(${JSON.stringify(res)}, {})`);
}

// Wait until the chart shows the expected symbol AND all relevant studies have
// finished recomputing for that symbol. dataWindowView() returns stale values
// from the previous symbol load until isLoading=false / isCompleted=true.
async function waitForReady(symExpect, maxMs = 12000) {
  const t0 = Date.now();
  let lastSeen = null;
  while (Date.now() - t0 < maxMs) {
    const status = await evalExpr(`(function(){
      var sym = ${CHART}._chartWidget.model().mainSeries().symbol();
      var sources = ${CHART}._chartWidget.model().model().dataSources();
      var allReady = true;
      var checked = 0;
      for (var i = 0; i < sources.length; i++) {
        var s = sources[i];
        if (!s.metaInfo) continue;
        var name = (s.metaInfo().description || s.metaInfo().shortDescription || '');
        if (!name) continue;
        // only gate on the indicators we read numeric values from
        if (name.indexOf('VWAP EMA') === -1 && name.indexOf('Relative Strength') === -1) continue;
        checked++;
        var loading = typeof s.isLoading === 'function' ? s.isLoading() : false;
        var completed = typeof s.isCompleted === 'function' ? s.isCompleted() : true;
        if (loading || !completed) { allReady = false; break; }
      }
      return { sym: sym, ready: allReady, checked: checked };
    })()`, 5000);
    lastSeen = status;
    if (status && status.sym && status.sym.indexOf(symExpect) !== -1 && status.ready && status.checked > 0) {
      return status.sym;
    }
    await new Promise(r => setTimeout(r, 250));
  }
  console.error(`  waitForReady timeout for ${symExpect} (last: ${JSON.stringify(lastSeen)})`);
  return null;
}

async function readIntradayState() {
  return await evalExpr(`(function(){
    var cw = ${CHART};
    var model = cw._chartWidget.model();
    var series = model.mainSeries();
    var sym = series.symbol();
    var bars = series.bars();
    var lastIdx = bars.lastIndex();
    var lastVal = bars.valueAt(lastIdx);
    var price = lastVal ? lastVal[4] : null;

    var sources = model.model().dataSources();
    var studyValues = {};

    // Compute PMH/PML directly from today's premarket 5m bars (4:00–9:30 AM ET).
    // The "Premarket High/Low Rays" indicator's labels can't be relied on
    // (they're empty when the indicator's visibility is toggled off, and
    // they only render after premarket close on some chart layouts).
    var pmh = null, pml = null;
    try {
      var fmt = new Intl.DateTimeFormat('en-US', {
        timeZone: 'America/New_York',
        year: 'numeric', month: '2-digit', day: '2-digit',
        hour: '2-digit', minute: '2-digit', hour12: false,
      });
      var nowParts = fmt.formatToParts(new Date());
      var np = {};
      for (var i = 0; i < nowParts.length; i++) np[nowParts[i].type] = nowParts[i].value;
      var todayET = np.year + '-' + np.month + '-' + np.day;
      var firstIdx = bars.firstIndex();
      var hi = -Infinity, lo = Infinity, found = 0;
      for (var idx = lastIdx; idx >= firstIdx; idx--) {
        var bv = bars.valueAt(idx);
        if (!bv) continue;
        var bp = fmt.formatToParts(new Date(bv[0] * 1000));
        var bpm = {};
        for (var j = 0; j < bp.length; j++) bpm[bp[j].type] = bp[j].value;
        var dateStr = bpm.year + '-' + bpm.month + '-' + bpm.day;
        if (dateStr !== todayET) {
          if (dateStr < todayET) break;
          continue;
        }
        var hhmm = parseInt(bpm.hour, 10) * 60 + parseInt(bpm.minute, 10);
        // Premarket window: 04:00 (240) ≤ time < 09:30 (570) ET
        if (hhmm >= 240 && hhmm < 570) {
          if (bv[2] > hi) hi = bv[2];
          if (bv[3] < lo) lo = bv[3];
          found++;
        }
      }
      if (found > 0) {
        pmh = Math.round(hi * 100) / 100;
        pml = Math.round(lo * 100) / 100;
      }
    } catch (e) { /* leave pmh/pml null on failure */ }

    for (var si = 0; si < sources.length; si++) {
      var s = sources[si];
      if (!s.metaInfo) continue;
      var meta = s.metaInfo();
      var name = meta.description || meta.shortDescription || '';
      if (!name) continue;

      try {
        var dwv = s.dataWindowView();
        if (dwv) {
          var items = dwv.items();
          if (items) {
            var values = {};
            for (var i = 0; i < items.length; i++) {
              var item = items[i];
              if (item._value && item._value !== '∅' && item._title) values[item._title] = item._value;
            }
            if (Object.keys(values).length > 0) studyValues[name] = values;
          }
        }
      } catch(e) {}
    }

    return { sym: sym, price: price, high: lastVal ? lastVal[2] : null, low: lastVal ? lastVal[3] : null,
             pmh: pmh, pml: pml, studyValues: studyValues };
  })()`, 8000);
}

async function readDailyBar() {
  return await evalExpr(`(function(){
    var cw = ${CHART};
    var bars = cw._chartWidget.model().mainSeries().bars();
    var endIdx = bars.lastIndex();
    var lastBar = bars.valueAt(endIdx);
    if (!lastBar) return { sym: null, pdh: null, pdl: null };

    // The chart's last daily bar is "today's in-progress bar" once the new
    // session begins (RTH open or first trade) and "yesterday's closed bar"
    // before that. Pick the right index for the prior trading day by
    // comparing the last bar's ET date to today's ET date.
    var fmtET = new Intl.DateTimeFormat('en-US', {
      timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit'
    });
    var lastBarDateET = fmtET.format(new Date(lastBar[0] * 1000));
    var todayET = fmtET.format(new Date());
    var priorBar = (lastBarDateET === todayET) ? bars.valueAt(endIdx - 1) : lastBar;

    return {
      sym: cw._chartWidget.model().mainSeries().symbol(),
      pdh: priorBar ? Math.round(priorBar[2]*100)/100 : null,
      pdl: priorBar ? Math.round(priorBar[3]*100)/100 : null,
      lastBarDateET: lastBarDateET,
      todayET: todayET,
      lastBarIsToday: lastBarDateET === todayET,
    };
  })()`, 5000);
}

// PASS 1: 5-minute reads
await setRes('5');
await new Promise(r => setTimeout(r, 1500));
console.error('Set resolution to 5m');

const pass1 = {};
for (const sym of SYMBOLS) {
  try {
    await setSymbol(sym);
    await waitForReady(sym, 12000);
    const data = await readIntradayState();
    pass1[sym] = data;
    const sv = data.studyValues || {};
    const rsi = (sv['Relative Strength Index'] || {}).RSI;
    const vwap = (sv['VWAP EMA 8/21 Trend Entriesv2'] || {}).VWAP;
    console.error(`5m  ${sym}: actual=${data.sym} price=${data.price} PMH=${data.pmh} PML=${data.pml} RSI=${rsi} VWAP=${vwap}`);
  } catch (e) {
    console.error(`5m  ${sym}: ERROR ${e.message}`);
    pass1[sym] = { error: e.message };
  }
}

// PASS 2: Daily reads
await setRes('D');
await new Promise(r => setTimeout(r, 1800));
console.error('Set resolution to D');

const pass2 = {};
for (const sym of SYMBOLS) {
  try {
    await setSymbol(sym);
    // Daily bars are fast — but still wait for studies on the new symbol.
    await waitForReady(sym, 8000);
    const data = await readDailyBar();
    pass2[sym] = data;
    console.error(`D   ${sym}: actual=${data.sym} PDH=${data.pdh} PDL=${data.pdl} (lastBar=${data.lastBarDateET}, today=${data.todayET}, lastIsToday=${data.lastBarIsToday})`);
  } catch (e) {
    console.error(`D   ${sym}: ERROR ${e.message}`);
    pass2[sym] = { error: e.message };
  }
}

// Restore
await setRes(origRes || '5');
await new Promise(r => setTimeout(r, 1200));
await setSymbol(origSym || 'QQQ');

const results = {};
for (const sym of SYMBOLS) {
  results[sym] = { ...(pass1[sym] || {}), ...(pass2[sym] || {}) };
}
console.log(JSON.stringify({ origSym, origRes, results }, null, 2));
await c.close();
