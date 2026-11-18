// Host page: one game pane (the game page web/game/, embedded with ?embed=1)
// plus the backend's metrics. The page drives the embed over postMessage
// (play, retry) and shows what it reports (status, fps, ms/frame, tic round
// trip). Every game renders its frames on its own Lakebase branch.
const $ = (id) => document.getElementById(id);
// Game size follows the window (index.html .pane max-width): the 16:10 game
// is at most as tall as the window below its top edge, so it never needs a
// scroll; the width the columns leave it caps it too (CSS).
function fitPane() {
  const pane = $('pane');
  if (!pane || document.fullscreenElement) return;
  const top = pane.getBoundingClientRect().top + window.scrollY;
  const h = window.innerHeight - top - 14;
  document.documentElement.style.setProperty('--pane-fit', `${Math.max(400, Math.floor(h * 1.6) + 2)}px`);
}
window.addEventListener('resize', fitPane);
window.addEventListener('load', fitPane);
fitPane();
// The game this page plays: a game on its own branch (menu, below); '' before one starts.
const GAME = { id: '', mode: '' };
// Live values (for the sidebar cards and Copy stats) and 60 s of history per metric.
const live = {};
const hist = { tic: [], fps: [], db: [], rtt: [], wire: [] };
const game = $('game');
let state = 'starting', retry = null;

const fmt = (v, d) => (typeof v === 'number' && isFinite(v) ? v.toFixed(d) : '\u2014');
// Joining waits for the player: a name (remembered per browser) and Play or
// Enter. Until then the game is loaded but not in the match. After the first
// Play, a stopped game rejoins on its own (retry, tab back in view).
let wantPlay = false;
const nickEl = $('nick');
nickEl.value = localStorage.getItem('sqldoom.nick') || '';
const play = () => game.contentWindow?.postMessage(
  { source: 'sqldoom-host', action: 'play', nick: nickEl.value.trim().slice(0, 12) }, '*');
// The name is kept as it is typed; the title menu sends it when a game starts.
// (Play and Leave game are gone, 2026-11-13: the menu joins the game, and
// Quit game ends it.)
const saveNick = () => localStorage.setItem('sqldoom.nick', nickEl.value.trim().slice(0, 12));
nickEl.addEventListener('input', saveNick);
nickEl.addEventListener('keydown', (e) => { if (e.key === 'Enter') { saveNick(); game.focus(); } });

// Change map: ends the level for everyone, then the chosen map ("next map" =
// the rotation's next). Seats carry over. No intermission: the loading screen
// (below) shows the referee's VACUUM log until the new map starts.
fetch('/api/maps').then((r) => r.json()).then(({ maps }) => {
  for (const name of maps || []) $('map-pick').add(new Option(name, name));
}).catch(() => {});
$('map-go').addEventListener('click', async () => {
  const name = $('map-pick').value;
  const btn = $('map-go');
  btn.disabled = true;
  try {
    const r = await fetch(`/api/match/map?name=${encodeURIComponent(name)}${gq()}`, { method: 'POST' });
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.detail || `HTTP ${r.status}`);
    status(`Map change requested: ${name === 'next' ? 'next map' : name}.`);
    showBetween({ active: true, title: `LOADING ${name === 'next' ? 'THE NEXT MAP' : name}`,
                  lines: ['map change requested, waiting for the end of the tic'], since: Date.now() / 1000 }, true);
  } catch (e) {
    status(`Map change failed: ${e.message}`, true);
  } finally {
    setTimeout(() => { btn.disabled = false; }, 3000);
    game.focus();
  }
});

// Render connections: 1, 2, 4 or 6 parallel frame connections (the game's
// render pool), 4 by default. 6 is the most a 32 CU primary takes next to
// the game loop (8 put the tic over budget, 2026-10-26). Remembered per browser; sent to the game before it joins and
// on every change, which resizes the pool without leaving the game.
// Auto (the default since 2026-11-12, after LBDoom's _pace_renderers): the
// tic comes first. Every second the page reads the last 3 s of tics: under
// 32 tics/s, or a p75 over 32 ms (past the 28.6 ms budget), takes one frame
// connection away; 34+ tics/s with a p75 under 27 ms adds one; anything in
// between holds; at most one change every 2 s, between 2 and 6.
// History: LBDoom's 26/22 held E1M6 at ~3 frames, 18 FPS, with the tic
// still at 35/s and 0 dropped (2026-11-12: loosened to 27/24). That still
// fell to 2 frames at the start of E1M6 with the tic at 26-27 ms and 35/s,
// where 4 frames played much better (owner, 2026-11-12): a slow tic that
// keeps 35/s costs nothing, and frames barely slow the tic (step 3j: 0, 4
// and 6 renders, tic 29, 29, 31 ms on E1M9). So only a game that really
// slows down (tics lost, or over budget) gives frames back. First version
// (p90, 2 s window, any second) ratcheted down to 1-2 on E1M6: one 250 ms
// tic put a 2 s window under 32.5 tics/s, and a p90 of 21-26 ms never let
// it grow again.
const AUTO_MIN = 2;
const CONN_CHOICES = [1, 2, 4, 6];
const CONN_DEFAULT = 4, AUTO_MAX = 6;
const saved = localStorage.getItem('sqldoom.renderConns');
let connsAuto = saved === null || saved === 'auto';
let renderConns = connsAuto ? CONN_DEFAULT : (CONN_CHOICES.includes(parseInt(saved, 10)) ? parseInt(saved, 10) : CONN_DEFAULT);
const sendConns = () => game.contentWindow?.postMessage({ source: 'sqldoom-host', action: 'render_conns', n: renderConns }, '*');
function markConns() {
  for (const b of document.querySelectorAll('#conns button')) {
    const auto = b.dataset.n === 'auto';
    b.classList.toggle('active', auto ? connsAuto : (!connsAuto && parseInt(b.dataset.n, 10) === renderConns));
    if (auto) b.textContent = connsAuto ? `auto \u00b7 ${renderConns}` : 'auto';
  }
}
for (const b of document.querySelectorAll('#conns button')) {
  b.addEventListener('click', () => {
    connsAuto = b.dataset.n === 'auto';
    if (!connsAuto) renderConns = parseInt(b.dataset.n, 10);
    localStorage.setItem('sqldoom.renderConns', connsAuto ? 'auto' : String(renderConns));
    markConns();
    sendConns();
    game.focus();
  });
}
markConns();
let paceChangedAt = 0;
setInterval(async () => {
  if (!connsAuto || state !== 'playing' || document.hidden) return;
  // The loading screen stops the tic (and the 3 s window after it still holds
  // that pause): not a slow game. Live 2026-11-13, each map change took the
  // pool down 2 frames, then back up 2-4 s later.
  if (betweenShown || performance.now() - betweenHiddenAt < 3500) return;
  let t;
  try { t = (await (await fetch(`/api/metrics?window=3${gq()}`)).json()).tic; } catch (e) { return; }
  if (!t || t.n < 30) return;                     // paused, or the referee restarting
  const now = performance.now(), p75 = t.p75_ms ?? t.p50_ms;
  if (now - paceChangedAt < 2000) return;
  let n = renderConns;
  if ((p75 > 32 || t.per_s < 32) && n > AUTO_MIN) n -= 1;
  else if (p75 < 27 && t.per_s >= 34 && n < AUTO_MAX) n += 1;
  else if (n < AUTO_MIN) n = AUTO_MIN;
  if (n !== renderConns) {
    renderConns = n; paceChangedAt = now;
    sendConns(); markConns();
  }
}, 1000);

// Frame time card: collapsed by default (keeps the page within one 1440p screen); remembered.
const bdCard = $('bd-card');
bdCard.open = localStorage.getItem('sqldoom.frameTimeOpen') === '1';
bdCard.addEventListener('toggle', () => localStorage.setItem('sqldoom.frameTimeOpen', bdCard.open ? '1' : '0'));

// Low-detail: render 160 scene columns instead of 320, doubled in the browser.
const ldBox = $('low-detail');
ldBox.checked = localStorage.getItem('sqldoom.lowDetail') === '1';
// the game window shrinks with low detail (2x instead of 3x, see index.html)
document.body.classList.toggle('low-detail', ldBox.checked);
const sendLowDetail = () => game.contentWindow?.postMessage(
  { source: 'sqldoom-host', action: 'low_detail', on: ldBox.checked }, '*');
ldBox.addEventListener('change', () => {
  localStorage.setItem('sqldoom.lowDetail', ldBox.checked ? '1' : '0');
  document.body.classList.toggle('low-detail', ldBox.checked);
  sendLowDetail();
  game.focus();
});

function status(text, bad = false) {
  $('status').textContent = text;
  $('status').classList.toggle('bad', bad);
}

// A stopped game (failed join, dropped connection) is asked to play again
// every 5 s while the tab is visible. The upstream page itself leaves the
// game when the tab goes to the background; coming back resumes it.
function scheduleRetry() {
  clearTimeout(retry);
  retry = setTimeout(() => { if (wantPlay && state === 'stopped' && !document.hidden) play(); }, 5000);
}
document.addEventListener('visibilitychange', () => {
  if (wantPlay && !document.hidden && state === 'stopped') play();
  // Single player: the world pauses while the tab is in the background and
  // goes on where it was when it comes back (the seat is kept, see
  // sqldoom/lakebase/games.py MODE_ENV). keepalive: the request still goes out as the
  // tab hides. Multiplayer goes on without you (your seat is kept 90 s).
  if (GAME.id && GAME.mode === 'solo') {
    fetch(`/api/games/${GAME.id}/away?on=${document.hidden ? 1 : 0}&tab=${hostTab()}`,
      { method: 'POST', keepalive: true }).catch(() => {});
    if (!document.hidden) status('Back in the game: the world was paused while you were away.');
  }
});

window.addEventListener('message', (ev) => {
  const m = ev.data;
  if (!m || m.source !== 'sqldoom') return;
  switch (m.kind) {
    case 'ready':
      sendConns();
      sendLowDetail();
      if (wantPlay) play();
      else nickEl.focus();
      break;
    case 'render_conns':
      live.conns = m.n;
      break;
    case 'score':
      renderScoreCard(m.rows || [], m.match, m.user);
      break;
    case 'state':
      state = m.state;
      $('pane').classList.toggle('live', state === 'playing');
            if (state === 'playing') {
        live.slot = m.slot;
        // Guests all log in as the app's identity; the name is what others see.
        const who = nickEl.value.trim() || m.user;
        status(`playing as ${who}, slot ${m.slot}. Click the game to grab the mouse.`);
        $('join-hint').textContent = `in the game as ${who}`;
      }
      if (state === 'stopped') {
        $('join-hint').textContent = wantPlay ? 'rejoining in 5 s' : 'Your name, as other players see it.';
        scheduleRetry();
      }
      break;
    case 'status':
      status(m.text, !!m.bad);
      break;
    case 'stats':
      onStats(m);
      break;
  }
});

// Loading screen between two maps (sqldoom/game/referee.py: a map change from the
// page, or a single-player level end): instead of the intermission, the
// referee's steps and VACUUM log over the game, until the new map starts.
// local: shown by the page itself right after the click, until the referee
// reports (or for 8 s at most).
let betweenShown = false, betweenLocal = null;   // {since (s), until (ms, performance.now)}
let betweenHiddenAt = -1e9;                       // auto frames in flight waits after it
function showBetween(b, local = false) {
  const el = $('between');
  if (local) {
    betweenLocal = { since: b.since, until: performance.now() + 8000 };
  } else if (b && b.active) {
    betweenLocal = null;
  } else if (betweenLocal && performance.now() < betweenLocal.until
             && !(b && b.ended && b.ended >= betweenLocal.since)) {
    return;                                       // the referee has not started the loading yet
  } else {
    betweenLocal = null;
  }
  const on = !!(b && b.active);
  if (on) {
    $('between-title').textContent = b.title || 'LOADING';
    $('between-log').textContent = (b.lines || []).join('\n');
    $('between-log').scrollTop = $('between-log').scrollHeight;
    const secs = b.since ? Math.max(0, Date.now() / 1000 - b.since) : 0;
    $('between-time').textContent = `${secs.toFixed(1)} s`;
  }
  if (on !== betweenShown) {
    el.hidden = !on; betweenShown = on;
    if (!on) betweenHiddenAt = performance.now();
    // no frame requests behind the loading screen: the referee's VACUUM FULL
    // then finds the tables free (render_pool.js doomPauseFrames)
    game.contentWindow?.postMessage({ source: 'sqldoom-host', action: 'frames_pause', on }, '*');
    if (!on) game.focus();
  }
}

// Backend metrics: the referee's tic cost, and the frame cost at the database.
async function pollMetrics() {
  for (;;) {
    try {
      const m = await (await fetch(`/api/metrics?window=5${gq()}`)).json();
      showBetween(m.between);
      const t = m.tic || {}, ref = m.referee || {};
      const dot = $('ref-dot');
      dot.className = `dot ${ref.state === 'running' ? 'ok' : 'bad'}`;
      dot.title = `referee ${ref.state ?? '?'}${ref.last_exit != null ? ` (last exit: ${ref.last_exit}; restarts ${ref.restarts})` : ''}`;
      const budget = typeof m.budget_ms === 'number' ? m.budget_ms : 28.6;
      Object.assign(live, { tic: t, budget, referee: ref.state });
      $('m-budget').textContent = fmt(budget, 1);
      setBig('m-tic', fmt(t.p50_ms, 1), 'ms', t.p50_ms > budget ? 'bad' : (t.p99_ms > budget ? 'warn' : ''));
      $('m-tic-sub').innerHTML = `p99 <span class="v">${fmt(t.p99_ms, 1)}</span> &middot; max <span class="v">${fmt(t.max_ms, 1)}</span>`
        + ` &middot; <span class="v">${t.over_budget ?? 0}</span> over &middot; <span class="v">${fmt(t.per_s, 0)}</span>/s`;
      push('tic', t.p50_ms); spark('sp-tic', hist.tic, budget);
      const srv = m.panes?.primary?.frame?.p50_ms ?? null;
      live.srv = srv;
      setBig('m-db', fmt(srv, 0), 'ms');
      $('m-db-sub').textContent = 'p50 on the game\u2019s branch';
      push('db', srv); spark('sp-db', hist.db);
    } catch (e) { /* app restarting; try again */ }
    await new Promise((r) => setTimeout(r, betweenShown ? 250 : 1000));   // the log moves fast
  }
}

pollMetrics();

// ---------------------------------------------------------------- sidebar
function push(k, v) {
  if (typeof v !== 'number' || !isFinite(v)) return;
  const a = hist[k]; a.push(v); if (a.length > 60) a.shift();
}
function setBig(id, text, unit, cls = '') {
  const el = $(id);
  el.className = `big ${cls}`.trim();
  el.innerHTML = `${text}${unit ? `<small>${unit}</small>` : ''}`;
}
// Sparkline: one polyline scaled to the window's max (and the reference
// line, e.g. the tic budget, drawn dashed).
function spark(id, a, ref) {
  const svg = $(id); if (!svg) return;
  const W = 84, H = 30, pad = 2;
  const hi = Math.max(1e-9, ref || 0, ...a) * 1.1;
  const y = (v) => (H - pad - (v / hi) * (H - 2 * pad)).toFixed(1);
  const pts = a.map((v, i) => `${(a.length === 1 ? W : (i * W) / (a.length - 1)).toFixed(1)},${y(v)}`).join(' ');
  svg.querySelector('polyline').setAttribute('points', pts);
  const line = svg.querySelector('line');
  if (line) {
    if (ref) { line.setAttribute('y1', y(ref)); line.setAttribute('y2', y(ref)); line.style.display = ''; }
    else line.style.display = 'none';
  }
}

function onStats(m) {
  Object.assign(live, { fps: m.fps, browserMs: m.msPerFrame, ticRtt: m.ticMs, kbps: m.kbps, wireKbps: m.wireKbps });
  if (m.renderConns != null) live.conns = m.renderConns;
  if (m.breakdown) live.bd = m.breakdown;
  const b = live.bd || {};
  setBig('m-fps', fmt(m.fps, 1), '');
  $('m-fps-sub').textContent = `${live.conns ?? '\u2014'} frame${live.conns === 1 ? '' : 's'} in flight, ${fmt(m.msPerFrame, 0)} ms each in the browser`;
  push('fps', m.fps); spark('sp-fps', hist.fps);
  // Round trip: the render connection's ping when measured; else the tic's.
  const rtt = typeof b.ping === 'number' ? b.ping : m.ticMs;
  setBig('m-rtt', fmt(rtt, 0), 'ms', rtt > 100 ? 'warn' : '');
  $('m-rtt-sub').textContent = typeof b.ping === 'number' ? 'SELECT 1 on a render connection' : 'one game tic';
  push('rtt', rtt); spark('sp-rtt', hist.rtt);
  const wire = typeof m.wireKbps === 'number' ? m.wireKbps : null;
  setBig('m-wire', fmt(wire ?? m.kbps, 0), 'KB/s');
  $('m-wire-sub').textContent = wire == null ? 'frames received'
    : `on the wire, from ${fmt(m.kbps, 0)} before delta+deflate`;
  push('wire', wire ?? m.kbps); spark('sp-wire', hist.wire);
  // frame time card
  const total = [b.db, b.net, b.xfer, b.decode, b.wait].every((v) => typeof v === 'number')
    ? b.db + b.net + b.xfer + b.decode + b.wait : null;
  $('bd-db').textContent = `${fmt(b.db, 0)} ms`;
  $('bd-net').textContent = `${fmt(b.net, 0)} ms`;
  const scale = total ? 150 / total : 0;   // bar widths: share of the total, max 150 px
  $('bar-db').style.width = `${Math.max(0, (b.db || 0) * scale)}px`;
  $('bar-net').style.width = `${Math.max(0, (b.net || 0) * scale)}px`;
  $('bd-xfer').textContent = `${fmt(b.xfer, 1)} ms`;
  $('bd-decode').textContent = `${fmt(b.decode, 1)} ms`;
  $('bd-wait').textContent = `${fmt(b.wait, 1)} ms`;
  $('bd-total').textContent = `${fmt(total, 0)} ms`;
  // one-line summary shown while the card is collapsed
  $('bd-summary').textContent = total == null ? '\u2014'
    : `db ${fmt(b.db, 0)} + net ${fmt(b.net, 0)} = ${fmt(total, 0)} ms`;
  $('bd-cam').textContent = `${fmt(b.camera, 0)} ms`;
  $('bd-gap').textContent = b.gapP50 == null ? '\u2014' : `${fmt(b.gapP50, 0)} / ${fmt(b.gapMax, 0)} ms`;
  const st = $('bd-stall');
  st.textContent = `${fmt(b.stall, 0)} ms`;
  st.className = b.stall > 50 ? 'v warn' : 'v';
  $('bd-rt').textContent = `${fmt(b.relayRt, 0)} \u00b7 ${fmt(b.ping, 0)} ms`;
  $('bd-tic').textContent = `${fmt(m.ticMs, 0)} ms`;
}

// Scoreboard card: four slots, the match's map and clock.
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
function renderScoreCard(rows, match, user) {
  const bySlot = new Map(rows.map((r) => [parseInt(r[0], 10), r]));
  const n = Math.max(4, ...bySlot.keys());
  let html = '';
  for (let s = 1; s <= n; s++) {
    const r = bySlot.get(s);
    if (!r || r[2] !== 't') { html += `<li><span class="slot">${s}</span><span class="who free">free</span></li>`; continue; }
    const [, role, , frags, health, alive, login] = r;
    const me = login === user || s === live.slot;
    html += `<li class="${me ? 'me' : ''}"><span class="slot">${s}</span><span class="who">${esc(role)}${me ? ' (you)' : ''}</span>`
      + `<span class="state">${frags} frags &middot; ${alive === 't' ? `${health} hp` : 'dead'}</span></li>`;
  }
  $('score-list').innerHTML = html;
  if (match) {
    const [state, mapName, levelTics, timerTics] = match;
    $('map-name').textContent = mapName || '\u2014';
    const lt = parseInt(levelTics, 10) || 0, tt = parseInt(timerTics, 10) || 0;
    const mmss = (sec) => `${Math.floor(sec / 60)}:${String(Math.floor(sec % 60)).padStart(2, '0')}`;
    const [, , , , interSec, nextMap] = match;
    const secs = parseInt(interSec, 10) || 0;
    // Game modes: during a switch next_map is DEATHMATCH, FINAL or SINGLE PLAYER.
    const label = { DEATHMATCH: 'deathmatch starts', FINAL: 'single player', 'SINGLE PLAYER': 'single player starts',
                    RESTART: 'level restarts' }[nextMap];
    $('map-time').textContent = state === 'intermission'
      ? (label ? `${label} in ${secs} s` : `intermission \u00b7 ${nextMap || 'next'} in ${secs} s`)
      : tt > 0 ? `${mmss(Math.max(0, (tt - lt) / 35))} left` : `${mmss(lt / 35)} in`;
    showChoice(state === 'intermission' && nextMap === 'FINAL', secs);
  }
}

// End of a deathmatch (one player left, or none): the final frag table is up
// in the game; here the choice. No answer within 30 s means single player; a
// player joining meanwhile starts a new deathmatch (sqldoom/game/referee.py).
function showChoice(on, secs) {
  $('dm-choice').hidden = !on;
  if (on) $('dm-choice-text').textContent = `Deathmatch over \u00b7 single player in ${secs} s`;
}
for (const [id, choice] of [['dm-stay', 'stay'], ['dm-solo', 'solo']]) {
  $(id).addEventListener('click', async () => {
    for (const b of document.querySelectorAll('#dm-choice button')) b.disabled = true;
    try {
      const r = await fetch(`/api/match/mode?choice=${choice}${gq()}`, { method: 'POST' });
      const body = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(body.detail || `HTTP ${r.status}`);
      status(choice === 'stay' ? 'Deathmatch again on this map, in a few seconds.' : 'Single player, in a few seconds.');
    } catch (e) {
      status(`Choice failed: ${e.message}`, true);
    } finally {
      setTimeout(() => { for (const b of document.querySelectorAll('#dm-choice button')) b.disabled = false; }, 3000);
      game.focus();
    }
  });
}

// Rules card: each mode's rules (sqldoom/server/rules.py). Player 1, the player
// seated longest, can change them; everyone else sees them read-only.
// Monsters and difficulty restart the level; the rest applies at once. Keys,
// multiplayer-only items and "on death" are fixed by the mode.
const rules = { data: null, dirty: false, picked: false };
const rulesForm = $('rules-form');
const tabToken = () => { try { return sessionStorage.getItem('sqldoom.tab') || ''; } catch (e) { return ''; } };
const FIXED = {
  solo: 'Fixed in single player: keys in the level, no multiplayer-only items.',
  deathmatch: 'Fixed in multiplayer: everyone holds all keys, multiplayer-only items on, respawn on death.',
};
function fillRules() {
  const d = rules.data;
  if (!d) return;
  const sel = $('rules-mode');
  if (!rules.picked) sel.value = d.mode;
  for (const o of sel.options) o.textContent = `Edit ${o.value === 'solo' ? 'single player' : 'multiplayer'} rules${o.value === d.mode ? ' (in effect)' : ''}`;
  const mode = sel.value, r = d.rules[mode] || {};
  const skill = rulesForm.elements.skill;
  if (skill.options.length !== d.skills.length) skill.innerHTML = d.skills.map((s, i) => `<option value="${i}">${esc(s)}</option>`).join('');
  const host = d.you_are_host;
  // Which set is in effect is not a choice: it follows the seated players.
  const inEffect = d.mode === 'solo' ? 'Single player rules' : 'Multiplayer rules';
  $('rules-who').innerHTML = `In effect: <b>${inEffect}</b>`
    + (d.mode === 'solo' ? ' (multiplayer rules switch on by themselves when a 2nd player joins).'
       : d.seated <= 1 ? ' (playing alone: they stay on until Player 1 goes back).'
       : ' (single player rules come back when one player is left).')
    + '<br>' + (d.host
      ? (host ? 'You are <b>Player 1</b>: change a setting, then <b>Save</b>.' : `Set by <b>${esc(d.host.name)}</b> (Player 1, seated longest).`)
      : 'Nobody is playing: the first player sets the rules.');
  if (!rules.dirty) {
    delete rulesForm.elements.monster_respawn.dataset.saved;   // re-read below
    for (const k of ['monsters', 'monster_respawn', 'item_respawn', 'weapons_stay']) rulesForm.elements[k].checked = !!r[k];
    for (const k of ['skill', 'monster_respawn_s', 'item_respawn_s']) rulesForm.elements[k].value = r[k];
    rulesForm.elements.death_restart.value = r.death_restart ? '1' : '0';
  }
  $('rule-death').hidden = mode !== 'solo';
  // without monsters, difficulty and monster respawn have nothing to act on
  const noMonsters = !rulesForm.elements.monsters.checked;
  $('rule-skill').hidden = noMonsters;
  $('rule-mrespawn').hidden = noMonsters;
  // Player 1 alone can pick the other rule set (the level restarts in 3 s);
  // with two or more players the multiplayer rules stay on.
  const canUse = host && d.state === 'playing' && !d.pending && (d.mode === 'solo' || d.seated <= 1);
  $('rules-use').hidden = !canUse;
  $('rules-use-btn').dataset.want = d.mode === 'solo' ? 'deathmatch' : 'solo';
  $('rules-use-btn').textContent = d.mode === 'solo' ? 'Play alone with the multiplayer rules' : 'Back to the single player rules';
  $('rule-fixed').textContent = FIXED[mode];
  for (const el of rulesForm.elements) if (el.id !== 'rules-save') el.disabled = !host;
  // Doom's Nightmare respawns monsters whatever the setting (the box is the
  // -respawn switch for the other difficulties): show it on and locked, keep
  // the saved choice for when the difficulty goes back down.
  const nm = +rulesForm.elements.skill.value === 4, mr = rulesForm.elements.monster_respawn;
  if (nm) {
    if (!('saved' in mr.dataset)) mr.dataset.saved = mr.checked ? '1' : '0';
    mr.checked = true; mr.disabled = true;
  } else if ('saved' in mr.dataset) {
    mr.checked = mr.dataset.saved === '1'; delete mr.dataset.saved;
  }
  $('mrespawn-forced').hidden = !nm;
  $('rules-save').disabled = !host || !rules.dirty;
  $('rules-save').classList.toggle('dirty', host && rules.dirty);
  $('rules-save').textContent = `Save ${mode === 'solo' ? 'single player' : 'multiplayer'} rules`;
  $('rules-note').innerHTML = host && rules.dirty ? 'Unsaved changes' : '<sup>*</sup> restarts the level';
}
async function loadRules() {
  try {
    const r = await fetch(`/api/match/rules?tab=${encodeURIComponent(tabToken())}${gq()}`);
    if (r.ok) { rules.data = await r.json(); fillRules(); }
  } catch (e) { /* next poll */ }
}
rulesForm.addEventListener('input', () => { rules.dirty = true; fillRules(); });
$('rules-mode').addEventListener('change', () => { rules.picked = true; rules.dirty = false; fillRules(); });
rulesForm.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const f = rulesForm.elements, mode = $('rules-mode').value;
  const values = {
    monsters: f.monsters.checked, skill: +f.skill.value,
    monster_respawn: 'saved' in f.monster_respawn.dataset ? f.monster_respawn.dataset.saved === '1' : f.monster_respawn.checked,
    monster_respawn_s: +f.monster_respawn_s.value,
    item_respawn: f.item_respawn.checked, item_respawn_s: +f.item_respawn_s.value,
    weapons_stay: f.weapons_stay.checked,
  };
  if (mode === 'solo') values.death_restart = f.death_restart.value === '1';
  $('rules-save').disabled = true;
  try {
    const r = await fetch(`/api/match/rules?mode=${mode}&tab=${encodeURIComponent(tabToken())}${gq()}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(values),
    });
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(typeof body.detail === 'string' ? body.detail : `HTTP ${r.status}`);
    const name = mode === 'solo' ? 'Single player' : 'Multiplayer';
    status(!body.changed.length ? 'Nothing changed.'
      : body.restart ? `${name} rules saved: the level restarts in a few seconds.`
      : mode === rules.data?.mode ? `${name} rules saved, in effect now.` : `${name} rules saved, used when the match switches.`);
    rules.dirty = false;
  } catch (e) {
    status(`Rules not saved: ${e.message}`, true);
  }
  await loadRules();
  game.focus();
});
$('rules-use-btn').addEventListener('click', async () => {
  const btn = $('rules-use-btn'), want = btn.dataset.want;
  btn.disabled = true;
  try {
    const r = await fetch(`/api/match/rules/use?mode=${want}&tab=${encodeURIComponent(tabToken())}${gq()}`, { method: 'POST' });
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(typeof body.detail === 'string' ? body.detail : `HTTP ${r.status}`);
    status(want === 'deathmatch' ? 'Multiplayer rules in 3 s: all keys, multiplayer-only items, respawn on death.'
                                 : 'Single player rules in 3 s.');
  } catch (e) {
    status(`Switch failed: ${e.message}`, true);
  } finally {
    btn.disabled = false;
    await loadRules();
    game.focus();
  }
});
loadRules();
setInterval(loadRules, 3000);

// Copy stats: every number on the page as plain text.
$('copy').addEventListener('click', async () => {
  const b = live.bd || {}, t = live.tic || {};
  const ld = live.bd?.lowDetail;
  const ldStr = ld ? ' \u00b7 low detail' : '';
  const text = [
    `SQLDoom on Lakebase \u00b7 ${new Date().toISOString().replace('T', ' ').slice(0, 19)} UTC`,
    `${live.conns ?? '?'} frames in flight${ldStr}`,
    `${fmt(live.fps, 1)} fps \u00b7 ${fmt(live.browserMs, 0)} ms/frame (browser) \u00b7 ${fmt(live.srv, 0)} ms/frame (at Lakebase)`,
    `tic p50 ${fmt(t.p50_ms, 1)} \u00b7 p99 ${fmt(t.p99_ms, 1)} \u00b7 max ${fmt(t.max_ms, 1)} ms \u00b7 ${t.over_budget ?? 0} over budget \u00b7 ${fmt(t.per_s, 0)}/s \u00b7 referee ${live.referee ?? '?'}`,
    `frame = db ${fmt(b.db, 0)} + net+proxy ${fmt(b.net, 0)} + transfer ${fmt(b.xfer, 1)} + decode ${fmt(b.decode, 1)} + wait ${fmt(b.wait, 1)} ms`,
    `camera ${fmt(b.camera, 0)} \u00b7 gap ${fmt(b.gapP50, 0)} / ${fmt(b.gapMax, 0)} \u00b7 stall ${fmt(b.stall, 0)} \u00b7 conn round trip ${fmt(b.relayRt, 0)} \u00b7 ping ${fmt(b.ping, 0)} \u00b7 tic round trip ${fmt(live.ticRtt, 0)} ms`,
    b.pipeline == null ? 'browser switches: not reported yet (no frame statistics yet)' :
    `browser switches: pipeline ${b.pipeline} per connection \u00b7 interpolate ${b.interpolate ? 'on' : 'off'} \u00b7 input at once ${b.inputNow === false ? 'off' : 'on'} \u00b7 coalesce ${b.coalesce ? 'on' : 'off'}`
      + (b.changed && b.changed.length
        ? ` \u00b7 CHANGED in this browser: ${b.changed.join(', ')} (localStorage.removeItem('<name>') and reload for the default)`
        : ' \u00b7 all defaults'),
    `wire ${fmt(live.wireKbps, 0)} KB/s from ${fmt(live.kbps, 0)} KB/s before delta+deflate`,
  ].join('\n');
  const btn = $('copy');
  try {
    await navigator.clipboard.writeText(text);
  } catch (e) {
    const ta = document.createElement('textarea');
    ta.value = text; document.body.appendChild(ta); ta.select();
    document.execCommand('copy'); ta.remove();
  }
  btn.textContent = 'Copied';
  setTimeout(() => { btn.textContent = 'Copy stats'; }, 1500);
});

$('fullscreen').addEventListener('click', () => {
  const pane = $('pane');
  (pane.requestFullscreen || pane.webkitRequestFullscreen)?.call(pane);
  game.focus();
});

// --- Title menu and loading screen: one Lakebase branch per game ----------
// Single player asks the app for a game of its own (POST /api/games: a new
// branch from game-template, sqldoom/lakebase/games.py), shows the loading steps until
// its referee ticks, then loads the game with ?game=<id>: every connection
// of the embed goes to that branch. Multiplayer opens a submenu: a new game
// (its own branch at 32 CU, deathmatch rules, up to 4 players) or one of the
// open games to join (refreshed every 3 s while the submenu shows).
// While a game is open the page touches it every 10 s (no touch for 180 s
// ends it); Quit game ends it at once and deletes its branch.
// (with the tab: a solo game answers its owner only, <user>#<tab>; without
// it /api/metrics?game= was 403, 2026-11-10)
function gq() { return GAME.id ? `&game=${GAME.id}&tab=${hostTab()}` : ''; }
function hostTab() {
  // The same per-tab token the embed creates (appjs_patch.py): the game
  // belongs to <user>#<token>, so it must exist before the embed loads.
  let t = '';
  try { t = sessionStorage.getItem('sqldoom.tab') || ''; } catch (e) { /* */ }
  if (!/^[a-z0-9]{1,12}$/.test(t)) {
    t = Math.random().toString(36).slice(2, 10) || 'tab';
    try { sessionStorage.setItem('sqldoom.tab', t); } catch (e) { /* */ }
  }
  return t;
}
const menuEl = $('menu'), loadEl = $('loading');
const STEPS = ['creating', 'warming', 'starting', 'ready'];
let menuSel = 0, keepAlive = null, loadingFor = '';
const menuItems = () => [...document.querySelectorAll('#menu-list li')].filter((li) => !li.hidden && !li.querySelector('button').disabled);
function markMenu() {
  const items = menuItems();
  menuSel = Math.max(0, Math.min(menuSel, items.length - 1));
  for (const li of document.querySelectorAll('#menu-list li')) li.classList.toggle('sel', items[menuSel] === li);
}
function stopEmbed() {
  wantPlay = false;
  clearTimeout(retry);
  game.contentWindow?.postMessage({ source: 'sqldoom-host', action: 'stop' }, '*');
  game.removeAttribute('src');
  $('pane').classList.remove('live');
}
async function showMenu(err = '') {
  clearInterval(keepAlive);
  keepAlive = null; loadingFor = '';
  stopEmbed();
  GAME.id = ''; GAME.mode = '';
  showRuns(null);
  loadEl.hidden = true;
  menuEl.hidden = false;
  $('to-menu').hidden = true;
  $('menu-err').textContent = err;
  await mainMenu();
  status('Choose a game.');
}
// One menu level: entries {label, sub, act, arg, disabled}.
let menuLevel = 'main', openTimer = null;
function renderMenu(entries, keepSel = false) {
  const ul = $('menu-list');
  ul.replaceChildren(...entries.map((en) => {
    const li = document.createElement('li');
    const b = document.createElement('button');
    b.textContent = en.label;
    b.disabled = !!en.disabled;
    if (en.sub) { const s = document.createElement('small'); s.textContent = en.sub; b.append(s); }
    b.addEventListener('click', () => chooseMenu(en.act, en.arg));
    li.addEventListener('mouseenter', () => { menuSel = menuItems().indexOf(li); markMenu(); });
    li.append(b);
    return li;
  }));
  if (!keepSel) menuSel = 0;
  markMenu();
}
async function mainMenu() {
  menuLevel = 'main';
  clearInterval(openTimer);
  let r = { enabled: false };
  try { r = await (await fetch(`/api/games/mine?tab=${hostTab()}`)).json(); } catch (e) { /* app restarting */ }
  const off = r.enabled ? '' : 'not available on this app (DOOM_GAMES=0)';
  const entries = [];
  if (r.game) entries.push({ label: 'Resume game', act: 'solo', sub: `your single-player game, ${r.game.state}, started ${Math.round(r.game.age_s / 60)} min ago` });
  entries.push({ label: 'Single player', act: 'solo', sub: off || 'your own world: a new Lakebase branch', disabled: !!off });
  entries.push({ label: 'Multiplayer', act: 'multi-menu', sub: off || 'host a game or join one, up to 4 players', disabled: !!off });
  if (menuLevel === 'main') renderMenu(entries);
}
async function multiMenu(keepSel = false) {
  menuLevel = 'multi';
  let open = [];
  try { open = (await (await fetch(`/api/games/open?tab=${hostTab()}`)).json()).games || []; } catch (e) { /* */ }
  if (menuLevel !== 'multi') return;
  const mine = open.find((g) => g.yours);
  const entries = [mine
    ? { label: 'Back to your game', act: 'join', arg: mine.game_id, sub: describe(mine) }
    : { label: 'New game', act: 'multi', sub: 'your branch at 32 CU; others join from this menu' }];
  for (const g of open.filter((x) => !x.yours)) {
    entries.push({ label: `Join ${g.players[0] || g.title || 'a game'}`, act: 'join', arg: g.game_id, sub: describe(g),
      disabled: g.state !== 'ready' });
  }
  if (open.filter((x) => !x.yours).length === 0) entries.push({ label: 'No game to join yet', act: '', disabled: true, sub: 'the list refreshes every 3 s' });
  entries.push({ label: 'Back', act: 'main-menu' });
  renderMenu(entries, keepSel);
}
function describe(g) {
  if (g.state !== 'ready') return `starting: ${g.step || g.state}`;
  const n = g.players.length;
  return `${g.map || '?'} \u00b7 ${n}/${g.max_players} player${n === 1 ? '' : 's'}${n ? `: ${g.players.join(', ')}` : ''}`;
}
function startEmbed(src, label) {
  menuEl.hidden = true;
  loadEl.hidden = true;
  $('to-menu').hidden = false;
  wantPlay = true;                    // the embed joins as soon as it is ready
  game.src = src;
  $('pane-label').textContent = label;
  status(`${label}: joining\u2026`);
  game.focus();
}
function showLoading(g, t0) {
  const at = Math.max(0, STEPS.indexOf(g.state));
  for (const li of document.querySelectorAll('#loading-steps li')) {
    const i = STEPS.indexOf(li.dataset.step);
    li.className = i < at || g.state === 'ready' ? 'done' : (i === at ? 'now' : '');
  }
  // Measured 2026-11-05: ~3 s branch, ~1-3 s cache, ~5 s referee.
  const secs = (performance.now() - t0) / 1000;
  const pct = g.state === 'ready' ? 100 : Math.min(95, at * 25 + Math.min(24, secs * 2));
  $('loading-bar').style.width = `${pct}%`;
  $('loading-time').textContent = `${secs.toFixed(0)} s${g.step ? ` \u00b7 ${g.step}` : ''}`;
}
async function startGame(mode) {
  $('menu-err').textContent = '';
  clearInterval(openTimer);
  let g;
  try {
    const nick = encodeURIComponent(nickEl.value.trim().slice(0, 12));
    const r = await fetch(`/api/games?mode=${mode}&tab=${hostTab()}&name=${nick}`, { method: 'POST' });
    g = await r.json();
    if (!r.ok) throw new Error(g.detail || `HTTP ${r.status}`);
  } catch (e) {
    $('menu-err').textContent = `Cannot start a game: ${e.message}`;
    return;
  }
  menuEl.hidden = true;
  loadEl.hidden = false;
  $('loading-err').textContent = '';
  $('loading-back').hidden = true;
  const id = g.game_id, t0 = performance.now();
  loadingFor = id;
  status('Creating your world on its own Lakebase branch\u2026');
  while (loadingFor === id) {
    showLoading(g, t0);
    if (g.state === 'ready') break;
    if (g.state === 'failed' || g.state === 'ended') {
      $('loading-err').textContent = `The game could not start: ${g.error || g.state}`;
      $('loading-back').hidden = false;
      status('The game could not start.', true);
      return;
    }
    await new Promise((res) => setTimeout(res, 500));
    try {
      const r = await fetch(`/api/games/${id}?tab=${hostTab()}`);
      if (r.ok) g = await r.json();
      else if (r.status === 404) g = { state: 'failed', error: 'the game is gone' };
    } catch (e) { /* app busy: ask again */ }
  }
  if (loadingFor !== id) return;      // back to the menu meanwhile
  status(`Your world is ready in ${((performance.now() - t0) / 1000).toFixed(1)} s.`);
  playGame(id, mode, g);
}
async function joinGame(id) {
  $('menu-err').textContent = '';
  let info = null;
  try {
    const r = await fetch(`/api/games/${id}/join?tab=${hostTab()}`, { method: 'POST' });
    info = await r.json();
    if (!r.ok) throw new Error(info.detail || `HTTP ${r.status}`);
  } catch (e) {
    $('menu-err').textContent = `Cannot join: ${e.message}`;
    multiMenu(true);
    return;
  }
  clearInterval(openTimer);
  playGame(id, 'multi', info);
}
function playGame(id, mode, info = null) {
  GAME.id = id; GAME.mode = mode;
  // Back at a solo game (resume, reload): the last page may have paused it as it unloaded.
  if (mode === 'solo' && !document.hidden) {
    fetch(`/api/games/${id}/away?on=0&tab=${hostTab()}`, { method: 'POST' }).catch(() => {});
  }
  startEmbed(`/game/?embed=1&game=${id}`, gameLabel(info, mode));
  showRuns(info);
  clearInterval(keepAlive);
  keepAlive = setInterval(async () => {
    try {
      const r = await fetch(`/api/games/${id}?tab=${hostTab()}`);
      if (r.status === 404 || r.status === 403) showMenu('Your game has ended (no player for a while, or the app ended it).');
      else if (r.ok && GAME.id === id) {
        const g = await r.json();
        $('pane-label').textContent = gameLabel(g, mode);
        showRuns(g);
      }
    } catch (e) { /* app restarting: the game is picked up again */ }
  }, 10000);
}
// "Lakebase branch g-1234abcd · 24 CU · single player": the size is the
// game endpoint's, read from the Lakebase API by the app (games.py _read_cu).
// "What it runs on": the game endpoint's size, Postgres version and region,
// as the Lakebase API reports them (games.py _read_cu); dashes at the menu.
function showRuns(g) {
  const cu = g && Array.isArray(g.endpoint_cu) && g.endpoint_cu.every((v) => typeof v === 'number')
    ? (g.endpoint_cu[0] === g.endpoint_cu[1] ? `${g.endpoint_cu[0]} CU` : `${g.endpoint_cu[0]}-${g.endpoint_cu[1]} CU`) : '\u2014';
  $('ro-cu').textContent = cu;
  $('ro-branch').textContent = g && g.branch ? g.branch : '\u2014';
  $('ro-branch-sub').textContent = g && g.mode === 'multi' ? 'your game\u2019s branch, multiplayer' : (g ? 'your game\u2019s branch, single player' : 'your game\u2019s branch');
  $('ro-pg').textContent = g && g.pg_version ? `PG ${g.pg_version}` : '\u2014';
  $('ro-region').textContent = g && g.region ? g.region : '\u2014';
}
function gameLabel(g, mode) {
  const kind = mode === 'multi' ? 'multiplayer' : 'single player';
  const cu = g && Array.isArray(g.endpoint_cu) && g.endpoint_cu.every((v) => typeof v === 'number')
    ? (g.endpoint_cu[0] === g.endpoint_cu[1] ? `${g.endpoint_cu[0]} CU` : `${g.endpoint_cu[0]}-${g.endpoint_cu[1]} CU`) : null;
  return ['Lakebase branch' + (g && g.branch ? ` ${g.branch}` : ''), cu, kind].filter(Boolean).join(' \u00b7 ');
}
function chooseMenu(act, arg) {
  if (act === 'solo' || act === 'multi') startGame(act);
  else if (act === 'join') joinGame(arg);
  else if (act === 'main-menu') mainMenu();
  else if (act === 'multi-menu') {
    multiMenu();
    clearInterval(openTimer);
    openTimer = setInterval(() => { if (!menuEl.hidden && menuLevel === 'multi') multiMenu(true); }, 3000);
  }
}
document.addEventListener('keydown', (e) => {
  if (menuEl.hidden || e.target === nickEl) return;
  const items = menuItems();
  if (e.key === 'ArrowDown') { menuSel = (menuSel + 1) % items.length; markMenu(); e.preventDefault(); }
  else if (e.key === 'ArrowUp') { menuSel = (menuSel - 1 + items.length) % items.length; markMenu(); e.preventDefault(); }
  else if (e.key === 'Enter') { items[menuSel]?.querySelector('button').click(); e.preventDefault(); }
  else if (e.key === 'Escape' && menuLevel === 'multi') { mainMenu(); e.preventDefault(); }
});
$('loading-back').addEventListener('click', () => showMenu());
$('to-menu').addEventListener('click', async () => {
  const id = GAME.id;
  const mode = GAME.mode;
  if (id) {
    try { await fetch(`/api/games/${id}/quit?tab=${hostTab()}`, { method: 'POST' }); } catch (e) { /* */ }
  }
  showMenu(!id ? '' : mode === 'multi' ? 'You left the game; it goes on for the others.'
    : 'Game over: your branch is being deleted.');
});
showMenu();
