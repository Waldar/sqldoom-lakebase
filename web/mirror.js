// Mirror pane: renders frames from a (possibly different) Lakebase endpoint,
// following the main game's slot and map. No input, no camera, no sound —
// just a SELECT from the same frame view the main pane uses.
//
// The main game runs in an iframe that posts state updates (slot, mapId) via
// the upstream embed protocol. This script listens for those, connects its
// own WebSocket to the mirror target, and blits frames as fast as it gets them.
import { PgConnection, OID } from '/upstream/pgwire.js';

const W = 320, H = 200;
const FRAMES_IN_FLIGHT = 2;
const $ = (id) => document.getElementById(id);

// ----------------------------------------------------------------- palette
function buildPalette(rows) {
  const lut = new Uint32Array(14 * 256);
  for (const [pal, idx, r, g, b] of rows) {
    lut[(+pal) * 256 + (+idx)] = (255 << 24) | ((+b) << 16) | ((+g) << 8) | (+r);
  }
  for (let i = 0; i < lut.length; i++) if (lut[i] === 0) lut[i] = 0xff000000;
  return lut;
}

// ------------------------------------------------------------------- state
let pg = null, lut = null, running = false;
let slot = -1, mapId = -1, frameMapId = -1, frameGen = 0, frameName = '';
let target = 'primary';                // switched by the stage selector
const canvas = $('mirror');
const ctx = canvas.getContext('2d', { alpha: false });
const image = ctx.createImageData(W, H);
const pixels = new Uint32Array(image.data.buffer);
const stats = { frames: 0, rtt: 0, since: performance.now() };

function blit(frame) {
  const base = frame[0] * 256;
  for (let i = 0; i < W * H; i++) pixels[i] = lut[base + frame[1 + i]];
  ctx.putImageData(image, 0, 0);
}

function setStatus(text) { $('mirror-status').textContent = text; $('mirror-status').hidden = !text; }

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// --------------------------------------------------------- connect + loop
async function connect() {
  if (pg) { try { pg.close(); } catch {} pg = null; }
  running = false; frameMapId = -1;
  setStatus('connecting\u2026');
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const url = `${proto}://${location.host}/pg?target=${encodeURIComponent(target)}&guest=1`;
  pg = new PgConnection(url, ['pg-delta']);
  pg.onclose = () => { running = false; setStatus('disconnected'); };
  await pg.connect({ guest: true });
  try { await pg.query('SET async_commit = on'); } catch {}
  // Load palettes and prepare helper statements
  await pg.prepare('palettes', 'SELECT pal, idx, r, g, b FROM api_palettes');
  await pg.prepare('slot', 'SELECT api_slot()');
  await pg.prepare('match',
    'SELECT state, map_name, level_tics, timer_tics, intermission_seconds, next_map, map_id, waiting, ahead_of_me, hold_seconds FROM api_match');
  const [pal] = await pg.run([{ name: 'palettes' }]);
  lut = buildPalette(pal.rows);
  setStatus('waiting for game\u2026');
  // Start polling for slot + mapId (the mirror needs both to know which
  // frame view to query; slot comes from the main pane's postMessage too,
  // but mapId is only available from api_match).
  pollSlotMap();
}

async function prepareFrame() {
  frameName = `mf${++frameGen}`; frameMapId = mapId;
  await pg.prepare(frameName, `SELECT frame_rgb FROM api_frame_idx_slot${slot}_m${mapId}`);
}

async function pollSlotMap() {
  while (running || pg) {
    try {
      const [sl, m] = await pg.run([{ name: 'slot' }, { name: 'match' }]);
      const s = parseInt(sl.rows[0]?.[0], 10);
      const mid = parseInt(m.rows[0]?.[6], 10);
      if (s > 0) slot = s;
      if (mid > 0) mapId = mid;
    } catch {}
    await sleep(1000);
  }
}

async function frameLoop() {
  while (running) {
    if (slot < 1 || mapId < 1) { await sleep(200); continue; }
    if (frameMapId !== mapId) {
      try { await prepareFrame(); } catch (e) {
        console.warn('mirror: frame view not ready:', e.message);
        await sleep(500); continue;
      }
    }
    const t0 = performance.now();
    try {
      const [result] = await pg.run([{ name: frameName, binary: true }]);
      const frame = result?.rows[0]?.[0];
      if (frame) {
        blit(frame);
        stats.frames++; stats.rtt += performance.now() - t0;
        setStatus('');
      } else {
        await sleep(100);
      }
    } catch (err) {
      if (!running) return;
      console.warn('mirror frame:', err.message);
      await sleep(100);
    }
  }
}

async function start() {
  try {
    await connect();
    running = true;
    for (let i = 0; i < FRAMES_IN_FLIGHT; i++) frameLoop();
  } catch (err) {
    setStatus(`mirror error: ${err.message}`);
    // Keep trying: the database may become reachable (e.g. role granted) later.
    setTimeout(start, 5000);
  }
}

// -------------------------------------------------- listen to main game
window.addEventListener('message', (ev) => {
  const m = ev.data;
  if (!m || m.source !== 'sqldoom') return;
  if (m.kind === 'state' && m.state === 'playing') {
    slot = m.slot || slot; mapId = m.mapId || mapId;
  }
  if (m.kind === 'status') {
    // The embedded game's status line (connecting, errors such as a refused login).
    $('status').textContent = `game: ${m.text}`;
    $('status').classList.toggle('bad', !!m.bad);
  }
  if (m.kind === 'stats') {
    // Update left pane stats from embed
    $('lf-fps').textContent = m.fps?.toFixed(1) ?? '\u2014';
    $('lf-ms').textContent = m.msPerFrame?.toFixed(0) ?? '\u2014';
  }
});

// ----------------------------------------------------- metrics poller
async function pollMetrics() {
  while (true) {
    try {
      const m = await (await fetch('/api/metrics?window=5')).json();
      const t = m.tic || {};
      const ref = m.referee || {};
      $('ref-state').textContent = ref.state ?? '?';
      $('ref-state').className = ref.state === 'running' ? 'val' : 'val bad';
      if (ref.state !== 'running' && ref.last_exit != null) {
        $('ref-state').title = `last exit: ${ref.last_exit}; restarts ${ref.restarts}`;
      }
      $('tic-p50').textContent = t.p50_ms?.toFixed(1) ?? '\u2014';
      $('tic-p99').textContent = t.p99_ms?.toFixed(1) ?? '\u2014';
      const maxEl = $('tic-max');
      maxEl.textContent = t.max_ms?.toFixed(1) ?? '\u2014';
      maxEl.className = t.max_ms > 28.6 ? 'val bad' : 'val';
      const overEl = $('tic-over');
      overEl.textContent = t.over_budget ?? 0;
      overEl.className = (t.over_budget ?? 0) > 0 ? 'val warn' : 'val';
      $('tic-rate').textContent = t.per_s?.toFixed(0) ?? '\u2014';
      // Mirror pane stats from /api/metrics
      const p = m.panes?.[target] || {};
      const f = p.frame || {};
      $('rf-fps').textContent = f.fps?.toFixed(1) ?? '\u2014';
      $('rf-ms').textContent = f.p50_ms?.toFixed(0) ?? '\u2014';
      const lagEl = $('rf-lag');
      if (p.lag_tics != null) {
        lagEl.textContent = `${p.lag_tics} tics (${p.lag_ms?.toFixed(0) ?? '?'} ms)`;
      } else if (p.lag_error) {
        lagEl.textContent = 'err';
      } else {
        lagEl.textContent = '\u2014';
      }
    } catch {}
    await sleep(2000);
  }
}

// Update mirror stats from its own frame loop (client-side)
setInterval(() => {
  const elapsed = performance.now() - stats.since;
  if (elapsed >= 1000 && stats.frames > 0) {
    // Client-side FPS/ms for the mirror pane (supplements the server-side
    // stats from /api/metrics which only see the relay's measurement)
    stats.frames = 0; stats.rtt = 0; stats.since = performance.now();
  }
}, 1000);

// ---------------------------------------------------------- stage selector
function enableStage(n) {
  for (const b of document.querySelectorAll('.stages button')) b.classList.remove('active');
  $(`s${n}`).classList.add('active');
}
// Stage 2/3 buttons are enabled by /api/health if a replica endpoint exists.
fetch('/api/health').then(r => r.json()).then(h => {
  if (h.panes?.includes('replica')) {
    $('s2').disabled = false;
    $('s2').addEventListener('click', () => { target = 'replica'; enableStage(2); restart(); });
  }
}).catch(() => {});
$('s1').addEventListener('click', () => { target = 'primary'; enableStage(1); restart(); });

async function restart() {
  $('mirror-label').textContent = target === 'primary' ? 'Lakebase Primary' : 'Read Replica';
  running = false;
  await sleep(200);
  start();
}

// ----------------------------------------------------------- auto-start
// Tell the upstream embed to play as a guest as soon as it reports ready.
const gameFrame = $('game');
window.addEventListener('message', (ev) => {
  const m = ev.data;
  if (!m || m.source !== 'sqldoom') return;
  if (m.kind === 'ready') {
    gameFrame.contentWindow.postMessage({ source: 'sqldoom-host', action: 'play' }, '*');
  }
  // A failed join (e.g. the database refused the login) leaves the game
  // stopped; ask it to play again every 5 s until it is in.
  if (m.kind === 'state' && m.state === 'stopped') {
    setTimeout(() => gameFrame.contentWindow.postMessage({ source: 'sqldoom-host', action: 'play' }, '*'), 5000);
  }
  // When the game reports playing, grab slot + mapId
  if (m.kind === 'state' && m.state === 'playing' && slot < 1) {
    // The embed posts slot and mapId in the state message.
    // If not available from the message, we'll poll via /api/metrics.
  }
});

pollMetrics();
start();
