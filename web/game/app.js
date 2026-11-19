// The browser client. It is the native client's join mode with the pygame
// parts swapped for a canvas and WebAudio: read the keyboard and mouse, hand
// the database one input row per 35 Hz tic, ask it for the camera and a frame
// as fast as it answers, blit, and play the sounds it reports. Every rule is
// SQL; this file holds no game logic. Even the camera interpolation is the
// database's (api_camera), so the browser never knows where it stands.
import { PgConnection, OID } from './pgwire.js';

const TIC_MS = 1000 / 35;
// Frames draw the newest committed tic (alpha 1). Interpolating between the
// last two tics on this page's clock showed the newest state only partly,
// about half a tic behind, and at 35 frames a second or fewer it buys no
// smoothness (LBDoom, 2026-11-17). localStorage.doomInterp = '1' goes back.
const INTERPOLATE = localStorage.getItem('doomInterp') === '1';
// A key or button change goes out at once instead of on the next 35 Hz
// input tick (0-28.6 ms later). localStorage.doomInputNow = '0' turns it off.
const INPUT_NOW = localStorage.getItem('doomInputNow') !== '0';
const INPUT_CODES = new Set(['KeyW', 'KeyS', 'KeyA', 'KeyD', 'KeyQ', 'KeyE', 'ArrowUp', 'ArrowDown',
  'ArrowLeft', 'ArrowRight', 'ShiftLeft', 'ShiftRight', 'ControlLeft', 'ControlRight', 'Space']);
let sendInputNow = null;   // set while playing
// Doom's cheat codes, typed while playing, single player only: the host page
// turns them on (action 'cheats'); each letter or digit goes to
// api_cheat_key, which also checks the match is solo.
let cheatsOn = false;
let sendCheat = null;      // set while playing
// The level's music: single player only, the host page's Music box
// (action 'music'); off, no track is fetched.
let musicOn = false;
// Always run (the host page's box, on by default): Shift then walks.
let alwaysRun = true;
const TURN_DEGREES_PER_TIC = 3.2;
const MOUSE_SENSITIVITY = 0.15;
const W = 320, H = 200;
const FRAMES_IN_FLIGHT = 2;   // see the frame loop; a third request only queued (measured over a 36 ms tailnet)
// The frame loop asks as fast as the database answers, which on a wide box
// is well past Doom's own 35 Hz. Every frame is 64 KB before the tunnel's
// coding, so the cap is the one knob on egress; config.json (max_fps, from
// the relay's DOOM_MAX_FPS) sets it, 0 means none.
let maxFps = 35;
let renderConns = 4;   // patched: render pool size, 1, 2, 4 or 6
let lowDetail = false;   // patched: low-detail frames (160 scene columns, doubled in JS)

const $ = (id) => document.getElementById(id);
const ui = {
  form: $('connect'), status: $('status'), stage: $('stage'), canvas: $('screen'),
  nick: $('nick'), nickField: $('nick-field'), userField: $('user-field'), passwordField: $('password-field'),
  accountToggle: $('account-toggle'),
  overlay: $('overlay'), overlayText: $('overlay-text'), score: $('scoreboard'), lobbyMap: $('lobby-map'),
  stats: $('stats'), target: $('target'), user: $('user'), password: $('password'),
  button: $('go'), targetField: $('target-field'), help: $('help'),
};
const ctx = ui.canvas.getContext('2d', { alpha: false });
const image = ctx.createImageData(W, H);
const pixels = new Uint32Array(image.data.buffer);

let pg = null;
let renderPool = [];   // patched: the frame connections (render_pool.js)
// patched: this browser tab's player token. The relay plays each tab as
// <signed-in user>#<token>, so two tabs are two players; every connection
// of the tab (control + render pool) sends the same token.
const doomTab = (() => {
  let t = '';
  try { t = sessionStorage.getItem('sqldoom.tab') || ''; } catch (e) { /* */ }
  if (!/^[a-z0-9]{1,12}$/.test(t)) {
    t = Math.random().toString(36).slice(2, 10) || 'tab';
    try { sessionStorage.setItem('sqldoom.tab', t); } catch (e) { /* */ }
  }
  return t;
})();
// The game this page plays (one Lakebase branch per game,
// sqldoom/lakebase/games.py), from the embed URL ?game=<id>.
const doomGame = (new URLSearchParams(location.search).get('game') || '').replace(/[^a-f0-9]/g, '').slice(0, 16);
const doomGameQ = doomGame ? `&game=${doomGame}` : '';
let clientParallel = null;   // from config.json: SET max_parallel_workers for this connection
let guestSeats = 0;          // from config.json: guest logins the relay can hand out
let accountMode = true;
let audio = null;
let running = false;
let embedded = false;        // ?embed=1 inside another page's iframe (the cloud demo's Deathmatch tab)

// Embedded, the page is only the screen: the host page draws the name field,
// the button and the two text lines in its own style and hears about them
// here. Messages carry no game state a player could act on; the host has the
// spectator's SQL for that.
const post = (kind, data = {}) => {
  if (!embedded) return;
  try { window.parent.postMessage({ source: 'sqldoom', kind, ...data }, '*'); } catch (e) { /* no parent */ }
};
const status = (text, bad = false) => {
  ui.status.textContent = text; ui.status.classList.toggle('bad', bad);
  post('status', { text, bad });
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------- input state
const keys = new Set();
const input = { mouseTurn: 0, pendingWeapon: null, pendingUse: false, wheel: 0, weaponKey: null, fireHeld: false };
const automap = { on: false };
const amPending = [];                // view changes to send with the next frame
let scoreHeld = false, dead = false, inLobby = false, intermission = false;
function refreshScore() { ui.score.hidden = !(scoreHeld || dead || inLobby || intermission); }

function isTyping() { return document.activeElement && document.activeElement.tagName === 'INPUT'; }

window.addEventListener('keydown', (ev) => {
  if (!running || isTyping()) return;
  if (ev.code === 'Tab') {
    ev.preventDefault();
    if (ev.shiftKey) { scoreHeld = true; refreshScore(); return; }
    if (!ev.repeat) automap.on = !automap.on;
    return;
  }
  if (ev.repeat) { ev.preventDefault(); return; }
  keys.add(ev.code);
  if (cheatsOn && sendCheat && !automap.on && /^(Key[A-Z]|Digit[0-9])$/.test(ev.code)) sendCheat(ev.code.slice(-1));
  if (ev.code === 'Space') input.pendingUse = true;
  if (/^Digit[1-7]$/.test(ev.code)) input.weaponKey = parseInt(ev.code[5], 10);
  if (automap.on) {
    if (ev.code === 'KeyF') amPending.push({ name: 'am_toggle', params: ['follow'] });
    if (ev.code === 'KeyG') amPending.push({ name: 'am_toggle', params: ['grid'] });
    if (ev.code === 'Home') amPending.push({ name: 'am_fit', params: [] });
    if (ev.code === 'Equal' || ev.code === 'NumpadAdd') amPending.push({ name: 'am_zoom', params: [1.25] });
    if (ev.code === 'Minus' || ev.code === 'NumpadSubtract') amPending.push({ name: 'am_zoom', params: [1 / 1.25] });
  }
  if (INPUT_CODES.has(ev.code) && sendInputNow) sendInputNow();
  if (!['F5', 'F11', 'F12'].includes(ev.code)) ev.preventDefault();
});
window.addEventListener('keyup', (ev) => {
  if (ev.code === 'Tab') { ev.preventDefault(); scoreHeld = false; refreshScore(); }
  const had = keys.delete(ev.code);
  if (had && INPUT_CODES.has(ev.code) && sendInputNow) sendInputNow();
});
window.addEventListener('blur', () => keys.clear());
// The mouse: a click on the screen locks the pointer while playing. Chrome
// returns a promise and refuses for reasons worth reading (an iframe without
// the permission, a request too soon after Esc); say so instead of nothing.
let lockAsksWithPromise = false;   // Chrome says why in the promise; the error event then only repeats it
ui.canvas.addEventListener('click', () => {
  if (!running) return;
  try {
    const p = ui.canvas.requestPointerLock();
    if (p && p.catch) {
      lockAsksWithPromise = true;
      p.catch((err) => status(`mouse capture refused: ${err.message}`, true));
    }
  } catch (err) { status(`mouse capture refused: ${err.message}`, true); }
});
document.addEventListener('pointerlockchange', () => {
  const locked = document.pointerLockElement === ui.canvas;
  post('pointer', { locked });
  if (running) status(locked ? 'mouse captured; Esc releases it' : 'mouse released; click the screen to capture it again');
});
document.addEventListener('pointerlockerror', () => {
  if (!lockAsksWithPromise) status('mouse capture failed; click the screen again', true);
});
ui.canvas.addEventListener('mousedown', (ev) => {
  if (ev.button === 0 && document.pointerLockElement === ui.canvas) { input.fireHeld = true; if (sendInputNow) sendInputNow(); }
});
window.addEventListener('mouseup', (ev) => {
  if (ev.button === 0 && input.fireHeld) { input.fireHeld = false; if (sendInputNow) sendInputNow(); }
});
window.addEventListener('mousemove', (ev) => {
  if (document.pointerLockElement === ui.canvas) input.mouseTurn += ev.movementX * MOUSE_SENSITIVITY;
});
ui.canvas.addEventListener('wheel', (ev) => {
  if (!running) return;
  if (automap.on) amPending.push({ name: 'am_zoom', params: [Math.pow(1.15, -Math.sign(ev.deltaY))] });
  else input.wheel += Math.sign(ev.deltaY);
  ev.preventDefault();
}, { passive: false });

const down = (...codes) => codes.some((c) => keys.has(c));

// keyTurn false: no turn from the turn keys. The tic adds up the turns of
// every input since the last tic, so an input sent between two ticks must
// not turn by a tick's worth again (the mouse's turn is sent once either way).
function readCommand(alive, keyTurn = true) {
  const enabled = alive;
  // With the automap up the arrows pan it instead.
  const arrowsPan = automap.on;
  if (arrowsPan) {
    const dx = (down('ArrowRight') ? 1 : 0) - (down('ArrowLeft') ? 1 : 0);
    const dy = (down('ArrowUp') ? 1 : 0) - (down('ArrowDown') ? 1 : 0);
    if (dx || dy) amPending.push({ name: 'am_pan', params: [dx * 16, dy * 16] });
  }
  const up = arrowsPan ? down('KeyW') : down('KeyW', 'ArrowUp');
  const back = arrowsPan ? down('KeyS') : down('KeyS', 'ArrowDown');
  const right = arrowsPan ? down('KeyE') : down('KeyE', 'ArrowRight');
  const left = arrowsPan ? down('KeyQ') : down('KeyQ', 'ArrowLeft');
  const fwd = enabled ? (up ? 1 : 0) - (back ? 1 : 0) : 0;
  const strafe = enabled ? (down('KeyD') ? 1 : 0) - (down('KeyA') ? 1 : 0) : 0;
  const turnKeys = enabled && keyTurn ? (right ? 1 : 0) - (left ? 1 : 0) : 0;
  const turn = enabled ? turnKeys * TURN_DEGREES_PER_TIC + input.mouseTurn : 0;
  input.mouseTurn = 0;
  const run = enabled && (alwaysRun !== down('ShiftLeft', 'ShiftRight'));
  // While dead, fire or use is the request to respawn (P_DeathThink); the
  // server decides when. The press just has to reach it.
  const fire = down('ControlLeft', 'ControlRight') || input.fireHeld || (!alive && down('Space'));
  const use = input.pendingUse;
  input.pendingUse = false;
  const weapon = input.pendingWeapon;
  input.pendingWeapon = null;
  return [fwd, strafe, run, turn, fire, weapon, use];
}

// -------------------------------------------------------------------- audio
class Audio {
  constructor() {
    this.ctx = new (window.AudioContext || window.webkitAudioContext)();
    this.buffers = new Map();
    this.loops = new Map();
    this.music = null;
    this.musicName = null;
  }
  async load(rows) {
    await Promise.all(rows.map(async ([name, wav]) => {
      try {
        this.buffers.set(name, await this.ctx.decodeAudioData(wav.buffer.slice(wav.byteOffset, wav.byteOffset + wav.byteLength)));
      } catch (e) { console.warn('cannot decode', name, e); }
    }));
  }
  _chain(name, volume, pan, loop) {
    const buffer = this.buffers.get(name);
    if (!buffer) return null;
    const src = this.ctx.createBufferSource();
    src.buffer = buffer;
    src.loop = loop;
    const gain = this.ctx.createGain();
    gain.gain.value = volume;
    let node = gain;
    if (this.ctx.createStereoPanner) {
      const panner = this.ctx.createStereoPanner();
      panner.pan.value = pan;
      gain.connect(panner);
      node = panner;
    }
    src.connect(gain);
    node.connect(this.ctx.destination);
    src.start();
    return { src, gain };
  }
  play(name, volume, pan) { if (volume > 0) this._chain(name, volume, pan, false); }
  setLoops(rows) {
    const wanted = new Map(rows.map(([key, name, volume, pan]) => [key, { name, volume: +volume, pan: +pan }]));
    for (const [key, chain] of this.loops) {
      if (!wanted.has(key)) { try { chain.src.stop(); } catch (e) { /* already ended */ } this.loops.delete(key); }
    }
    for (const [key, { name, volume, pan }] of wanted) {
      const chain = this.loops.get(key);
      if (chain) chain.gain.gain.value = volume;
      else { const c = this._chain(name, volume, pan, true); if (c) this.loops.set(key, c); }
    }
  }
  stopAll() { for (const [, chain] of this.loops) { try { chain.src.stop(); } catch (e) { /* */ } } this.loops.clear(); }
  async setMusic(name, bytes) {
    if (this.musicName === name) return;
    this.stopMusic();
    this.musicName = name;
    if (!bytes || !bytes.byteLength) return;
    let buffer;
    try {
      buffer = await this.ctx.decodeAudioData(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    } catch (e) { console.warn('cannot decode music', name, e); return; }
    if (this.musicName !== name) return;           // the map changed while decoding
    const src = this.ctx.createBufferSource();
    src.buffer = buffer; src.loop = true;
    const gain = this.ctx.createGain();
    gain.gain.value = 0.35;
    src.connect(gain); gain.connect(this.ctx.destination);
    src.start();
    this.music = { src, gain };
  }
  stopMusic() {
    if (this.music) { try { this.music.src.stop(); } catch (e) { /* already ended */ } this.music = null; }
    this.musicName = null;
  }
}

// ----------------------------------------------------------------- palette
function buildPalette(rows) {
  const lut = new Uint32Array(14 * 256);           // ABGR for a little-endian Uint32 view of RGBA bytes
  for (const [pal, idx, r, g, b] of rows) {
    lut[(+pal) * 256 + (+idx)] = (255 << 24) | ((+b) << 16) | ((+g) << 8) | (+r);
  }
  for (let i = 0; i < lut.length; i++) if (lut[i] === 0) lut[i] = 0xff000000;
  return lut;
}

function blit(frame, lut) {
  const base = frame[0] * 256;
  for (let i = 0; i < W * H; i++) pixels[i] = lut[base + frame[1 + i]];
  ctx.putImageData(image, 0, 0);
}

// The automap comes back as RGB bytes, the same buffer the native client blits.
function blitRGB(rgb) {
  for (let i = 0, j = 0; i < W * H; i++, j += 3) pixels[i] = 0xff000000 | (rgb[j + 2] << 16) | (rgb[j + 1] << 8) | rgb[j];
  ctx.putImageData(image, 0, 0);
}

// -------------------------------------------------------------------- game
async function play(user, password, target, nick, guest) {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const url = `${proto}://${location.host}/pg?target=${encodeURIComponent(target)}${guest ? '&guest=1' : ''}&tab=${doomTab}${doomGameQ}`;   // patched: per-tab player, per-game branch
  pg = new PgConnection(url, ['pg-delta']);
  pg.onclose = (err) => { if (running) stop(`disconnected: ${err.message}`, true); };
  status(guest ? 'asking for a guest seat ...' : 'connecting ...');
  await pg.connect(guest ? { guest: true } : { user, password });
  user = pg.user;
  status(`signed in as ${user}; loading palettes and sounds ...`);
  if (clientParallel) {
    // One renderer does not need the whole machine; see MULTIPLAYER.md.
    try { await pg.query(`SET max_parallel_workers = ${parseInt(clientParallel, 10)}`); } catch (e) { console.warn('max_parallel_workers not supported by this server:', e.message); }
  }

  await pg.prepare('palettes', 'SELECT pal, idx, r, g, b FROM api_palettes');
  await pg.prepare('sounds_all', 'SELECT name, wav_data FROM sound_assets');
  await pg.prepare('join', 'SELECT api_join()');
  await pg.prepare('slot', 'SELECT api_slot()');
  await pg.prepare('setname', 'SELECT api_set_name($1)', [OID.text]);
  await pg.prepare('score', 'SELECT slot, role_name, connected, frags, health, alive, login FROM api_scoreboard');
  await pg.prepare('match', 'SELECT state, map_name, level_tics, timer_tics, intermission_seconds, next_map, map_id, waiting, ahead_of_me, hold_seconds FROM api_match');
  await pg.prepare('me', 'SELECT alive, health, frags, position_x, position_y FROM api_player_state');
  await pg.prepare('automap', 'SELECT api_automap()', []);
  await pg.prepare('am_pan', 'SELECT api_automap_pan($1,$2)', [OID.float8, OID.float8]);
  await pg.prepare('am_zoom', 'SELECT api_automap_zoom($1)', [OID.float8]);
  await pg.prepare('am_toggle', 'SELECT api_automap_toggle($1)', [OID.text]);
  await pg.prepare('am_fit', 'SELECT api_automap_fit()', []);
  await pg.prepare('input', 'SELECT api_input($1,$2,$3,$4,$5,$6,$7)',
    [OID.float4, OID.float4, OID.bool, OID.float4, OID.bool, OID.int4, OID.bool]);
  await pg.prepare('camera', 'SELECT api_camera($1)', [OID.float8]);
  await pg.prepare('events', 'SELECT event_id, sound_name, volume, pan FROM api_sound_events WHERE event_id > $1 ORDER BY event_id', [OID.int8]);
  await pg.prepare('events_max', 'SELECT COALESCE(MAX(event_id), 0) FROM api_sound_events');
  await pg.prepare('loops', 'SELECT loop_key, sound_name, volume, pan FROM api_sound_loops');
  await pg.prepare('music', 'SELECT name, audio_data, audio_format FROM api_stage_music');
  await pg.prepare('weapon_slot', 'SELECT api_weapon_slot($1)', [OID.int4]);
  await pg.prepare('cheat', 'SELECT api_cheat_key($1)', [OID.text]);
  await pg.prepare('weapon_cycle', 'SELECT api_weapon_cycle($1)', [OID.int4]);
  await pg.prepare('map_geo', 'SELECT x1, y1, x2, y2, solid FROM api_map_geometry');
  await pg.prepare('live', 'SELECT kind, name, x, y, angle, alive FROM api_things_live WHERE map_id = $1', [OID.int4]);

  const [pal, snd] = await pg.run([{ name: 'palettes' }, { name: 'sounds_all', binary: true }]);
  const lut = buildPalette(pal.rows);
  audio = new Audio();
  await audio.load(snd.rows.map(([name, wav]) => [new TextDecoder().decode(name), wav]));

  // The lobby: claim a slot, or wait for one to free up.
  let announced = null;   // which of the two waits was last said, so a change is said again
  // The level outline for the map being played, fetched once per map. Waiting
  // used to be a grey panel; this is the match, live, while you queue.
  const lobbyMap = { mapId: -1, lines: [], bounds: null };
  const lobbyCtx = ui.lobbyMap.getContext('2d', { alpha: false });
  // The cloud console draws this same plan view in SVG while you are idle
  // (DoomTab.tsx, MapOverview) and hands over to this one the moment you
  // queue, so the two share a palette: one-sided walls bone, two-sided dim
  // red, monsters red, a player an arrow in its own colour.
  const WALL_SOLID = '#efe6d8', WALL_OPEN = '#6e2a25', MONSTER = '#c2352c';
  const PLAYER_COLOURS = ['#4fbf4f', '#7b7bff', '#c48a4a', '#ff5a4a'];

  async function drawLobby(mapId, mapName) {
    if (mapId === undefined || mapId === null || mapId < 0) return;
    if (lobbyMap.mapId !== mapId) {
      const [geo] = await pg.run([{ name: 'map_geo' }]);
      if (!geo.rows.length) return;            // between maps: keep the last outline
      lobbyMap.lines = geo.rows.map(([x1, y1, x2, y2, solid]) =>
        [parseFloat(x1), parseFloat(y1), parseFloat(x2), parseFloat(y2), solid === 't' || solid === true]);
      const xs = lobbyMap.lines.flatMap((l) => [l[0], l[2]]);
      const ys = lobbyMap.lines.flatMap((l) => [l[1], l[3]]);
      lobbyMap.bounds = [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
      lobbyMap.mapId = mapId;
    }
    if (!lobbyMap.bounds) return;
    const [things] = await pg.run([{ name: 'live', params: [mapId] }]);

    // Its own backing store at the element's real size: the game canvas is
    // 320x200 upscaled, and a plan view drawn there would go blocky exactly
    // where the console's SVG is crisp.
    const dpr = window.devicePixelRatio || 1;
    const cw = Math.max(1, Math.round(ui.lobbyMap.clientWidth * dpr));
    const ch = Math.max(1, Math.round(ui.lobbyMap.clientHeight * dpr));
    if (ui.lobbyMap.width !== cw || ui.lobbyMap.height !== ch) {
      ui.lobbyMap.width = cw; ui.lobbyMap.height = ch;
    }
    // The console's viewBox: 64 map units of margin, fitted xMidYMid meet.
    const pad = 64;
    const [minX, minY, maxX, maxY] = lobbyMap.bounds;
    const vw = maxX - minX + 2 * pad, vh = maxY - minY + 2 * pad;
    const scale = Math.min(cw / vw, ch / vh);
    const offX = (cw - vw * scale) / 2, offY = (ch - vh * scale) / 2;
    // Map y grows northwards, canvas y downwards.
    const sx = (x) => offX + (x - (minX - pad)) * scale;
    const sy = (y) => offY + ((maxY + pad) - y) * scale;
    const r = (Math.max(vw, vh) / 90) * scale;          // marker radius, in pixels
    const font = (Math.max(vw, vh) / 45) * scale;

    ui.lobbyMap.hidden = false;
    ui.overlay.classList.add('queue');   // the notice steps out of the way
    lobbyCtx.fillStyle = '#000';
    lobbyCtx.fillRect(0, 0, cw, ch);
    for (const [x1, y1, x2, y2, solid] of lobbyMap.lines) {
      lobbyCtx.strokeStyle = solid ? WALL_SOLID : WALL_OPEN;
      lobbyCtx.lineWidth = (solid ? 1.2 : 1) * dpr;     // the console's non-scaling stroke
      lobbyCtx.beginPath();
      lobbyCtx.moveTo(sx(x1), sy(y1));
      lobbyCtx.lineTo(sx(x2), sy(y2));
      lobbyCtx.stroke();
    }
    let playerIndex = 0;
    for (const [kind, name, x, y, angle, alive] of things.rows) {
      const px = sx(parseFloat(x)), py = sy(parseFloat(y));
      const up = alive === 't' || alive === true;
      if (kind === 'monster') {
        if (!up) continue;
        lobbyCtx.fillStyle = MONSTER;
        lobbyCtx.strokeStyle = '#000';
        lobbyCtx.lineWidth = 0.5 * dpr;
        lobbyCtx.beginPath();
        lobbyCtx.arc(px, py, r * 0.7, 0, Math.PI * 2);
        lobbyCtx.fill(); lobbyCtx.stroke();
        continue;
      }
      // A player: the console's arrow, pointing where they face.
      const colour = PLAYER_COLOURS[playerIndex++ % PLAYER_COLOURS.length];
      const rad = (parseFloat(angle) * Math.PI) / 180;
      lobbyCtx.globalAlpha = up ? 1 : 0.45;
      lobbyCtx.fillStyle = colour;
      lobbyCtx.strokeStyle = '#000';
      lobbyCtx.lineWidth = (r / 6) * dpr;
      lobbyCtx.beginPath();
      lobbyCtx.moveTo(px + Math.cos(rad) * r * 2.2, py - Math.sin(rad) * r * 2.2);
      lobbyCtx.lineTo(px + Math.cos(rad + 2.4) * r * 1.3, py - Math.sin(rad + 2.4) * r * 1.3);
      lobbyCtx.lineTo(px + Math.cos(rad - 2.4) * r * 1.3, py - Math.sin(rad - 2.4) * r * 1.3);
      lobbyCtx.closePath();
      lobbyCtx.fill(); lobbyCtx.stroke();
      if (name) {
        lobbyCtx.font = `600 ${font}px ui-monospace, monospace`;
        lobbyCtx.textAlign = 'center';
        lobbyCtx.lineWidth = font * 0.35;
        lobbyCtx.strokeStyle = '#000';
        lobbyCtx.strokeText(name, px, py - r * 3);
        lobbyCtx.fillText(name, px, py - r * 3);
      }
      lobbyCtx.globalAlpha = 1;
    }
    // The console's caption, same place, same words.
    const players = things.rows.filter((t) => t[0] === 'player').length;
    const monsters = things.rows.filter((t) => t[0] === 'monster').length;
    lobbyCtx.font = `${font * 0.9}px ui-monospace, monospace`;
    lobbyCtx.textAlign = 'left';
    lobbyCtx.fillStyle = '#c9a99c';
    lobbyCtx.fillText(`${mapName || ''} · ${players} ${players === 1 ? 'player' : 'players'}, ${monsters} monsters`,
      offX + font, offY + font * 1.4);
  }
  for (;;) {
    let j, s, m;
    try {
      [j, s, m] = await pg.run([{ name: 'join' }, { name: 'score' }, { name: 'match' }]);
    } catch (err) {
      // Two joins racing for one slot, or the referee handing a slot back at
      // the same moment: Postgres reports a serialization failure. Try again.
      if (err.code === '40001' || /concurrent/i.test(err.message)) { await sleep(200); continue; }
      throw err;
    }
    renderScore(s.rows, user);
    if (parseInt(j.rows[0][0], 10) >= 0) break;
    const between = m.rows[0] && m.rows[0][0] !== 'playing';
    const waiting = m.rows[0] ? parseInt(m.rows[0][7], 10) : 0;
    const ahead = m.rows[0] && m.rows[0][8] !== null ? parseInt(m.rows[0][8], 10) : 0;
    if (announced !== between) { status(between ? 'the match is between maps; joining when the next one starts ...' : 'all four slots are taken; you are in the queue, first come first served ...'); announced = between; }
    ui.overlay.hidden = false;
    ui.overlayText.textContent = between ? `BETWEEN MAPS — ${m.rows[0][5]} IS NEXT`
      : (ahead > 0 ? `WAITING FOR A SLOT — ${ahead} AHEAD OF YOU` : 'WAITING FOR A SLOT — YOU ARE NEXT')
        + (waiting > 1 ? `\n${waiting} WAITING` : '');
    inLobby = true; refreshScore();
    post('state', { state: 'lobby' });
    // A failed draw must not cost anyone their place in the queue: the join
    // heartbeat above is what holds it.
    try {
      await drawLobby(m.rows[0] ? parseInt(m.rows[0][6], 10) : -1, m.rows[0] ? m.rows[0][1] : '');
    } catch (e) {
      console.warn('lobby view unavailable:', e.message);
    }
    await sleep(1000);
  }
  inLobby = false; refreshScore();
  ui.lobbyMap.hidden = true;
  ui.overlay.classList.remove('queue');   // the intermission notice wants the middle back
  if (nick) { try { await pg.run([{ name: 'setname', params: [nick] }]); } catch (e) { console.warn('name not set:', e.message); } }
  const [s] = await pg.run([{ name: 'slot' }]);
  const slot = parseInt(s.rows[0][0], 10);
  // The frame view is rebuilt by the referee on every map change, so the
  // statement over it is prepared under a fresh name each time it is needed.
  // One frame view per slot and map (api_frame_idx_slot<n>_m<map>); the
  // statement over it is prepared under a fresh name whenever the map changes.
  let frameGen = 0, frameName = '', frameMap = -1, frameSql = '';
  const match = { state: 'playing', map: '', mapId: -1, left: 0, next: '', seconds: 0, waiting: 0, hold: 0 };
  const joinedAt = performance.now();
  const prepareFrame = async () => {
    frameName = `frame${++frameGen}`; frameMap = match.mapId;
    frameSql = `SELECT frame_rgb FROM api_frame_idx_slot${slot}_m${match.mapId}${lowDetail ? '_low' : ''}`;   // patched: each render connection prepares it
  };
  const readMatch = (row) => {
    if (!row) return;
    const was = match.map;
    match.state = row[0]; match.map = row[1]; match.mapId = parseInt(row[6], 10);
    const timer = parseInt(row[3], 10);
    match.left = timer > 0 ? Math.max(0, Math.round((timer - parseInt(row[2], 10)) / 35)) : -1;
    match.seconds = parseInt(row[4], 10); match.next = row[5];
    match.waiting = parseInt(row[7], 10) || 0; match.hold = parseInt(row[9], 10) || 0;
    intermission = match.state === 'intermission'; refreshScore();
    if (intermission) {
      ui.overlay.hidden = false;
      ui.overlayText.textContent = match.next === 'DEATHMATCH'   // patched: game modes
        ? `DEATHMATCH STARTS IN ${match.seconds}`
        : match.next === 'FINAL'
          ? `DEATHMATCH OVER — STAY OR GO SOLO? SINGLE PLAYER IN ${match.seconds} s`
          : match.next === 'SINGLE PLAYER'
            ? `SINGLE PLAYER STARTS IN ${match.seconds}`
            : match.next === 'RESTART'
              ? `LEVEL RESTARTS IN ${match.seconds}`
              : `${match.map} COMPLETE — ${match.next} IN ${match.seconds} s`;
    }
    if (was && match.map !== was) status(`now on ${match.map}, slot ${slot}`);
    if (match.map !== was) loadMusic();
  };
  const loadMusic = async () => {
    if (!audio) return;
    if (!musicOn) { audio.stopMusic(); return; }
    try {
      const [m] = await pg.run([{ name: 'music', binary: true }]);
      const row = m.rows[0];
      if (!row) { audio.stopMusic(); return; }
      await audio.setMusic(new TextDecoder().decode(row[0]), row[1]);
    } catch (e) { console.warn('music unavailable', e); }
  };
  window.doomMusic = () => { if (running) loadMusic(); };
  readMatch((await pg.run([{ name: 'match' }]))[0].rows[0]);
  await prepareFrame();
  ui.overlay.hidden = true;
  status(`in the game as ${user}, slot ${slot}. Click the screen to grab the mouse.`);
  ui.help.hidden = false;

  running = true;
  ui.stage.classList.add('live');
  ui.stage.focus();
  post('state', { state: 'playing', user, slot });
  const stats = { frames: 0, bytes: 0, rtt: 0, tics: 0, ticRtt: 0, since: performance.now(), alive: true, health: 100, frags: 0, x: 0, y: 0 };
  // Bytes on the wire come from the relay once a second (pgwire.js onwire);
  // the difference between two reports is this second's egress.
  let wireAt = performance.now(), wireBytes = pg.wire ? pg.wire.wire_out : 0, wireKbps = null;
  pg.onwire = (w) => {
    const now = performance.now();
    if (now - wireAt >= 500) wireKbps = (w.wire_out - wireBytes) / ((now - wireAt) / 1000);
    wireAt = now; wireBytes = w.wire_out;
  };
  let lastEvent = parseInt((await pg.run([{ name: 'events_max' }]))[0].rows[0][0], 10);
  let lastTic = performance.now();
  let ticInFlight = 0;

  // 35 Hz: input out, sounds and my own state back, one round trip.
  const ticker = setInterval(async () => {
    if (!running || ticInFlight > 2) return;
    ticInFlight++;
    try {
      if (input.weaponKey !== null) {
        const k = input.weaponKey; input.weaponKey = null;
        const [w] = await pg.run([{ name: 'weapon_slot', params: [k] }]);
        const id = parseInt(w.rows[0][0], 10);
        if (id >= 0) input.pendingWeapon = id;
      }
      if (input.wheel !== 0) {
        const step = Math.sign(input.wheel); input.wheel = 0;
        const [w] = await pg.run([{ name: 'weapon_cycle', params: [step] }]);
        const id = parseInt(w.rows[0][0], 10);
        if (id >= 0) input.pendingWeapon = id;
      }
      const command = readCommand(stats.alive);
      lastTic = performance.now();
      const [, me, ev, lp] = await pg.run([
        { name: 'input', params: command },
        { name: 'me' },
        { name: 'events', params: [lastEvent] },
        { name: 'loops' },
      ]);
      // The tic's latency as the player feels it: input out, own state back.
      stats.ticRtt += performance.now() - lastTic; stats.tics++;
      if (me.rows.length) {
        stats.alive = me.rows[0][0] === 't';
        stats.health = parseInt(me.rows[0][1], 10);
        stats.frags = parseInt(me.rows[0][2], 10);
        stats.x = parseFloat(me.rows[0][3]); stats.y = parseFloat(me.rows[0][4]);
        dead = !stats.alive; refreshScore();
      }
      for (const [id, name, volume, pan] of ev.rows) {
        lastEvent = Math.max(lastEvent, parseInt(id, 10));
        audio.play(name, +volume, +pan);
      }
      audio.setLoops(lp.rows);
      if (!intermission) {
        ui.overlay.hidden = stats.alive;
        if (!stats.alive) ui.overlayText.textContent = 'YOU DIED — FIRE OR SPACE TO RESPAWN';
      }
    } catch (err) {
      if (running) console.warn('tic dropped:', err.message);
    } finally {
      ticInFlight--;
    }
  }, TIC_MS);
  // A change of keys or buttons: the same input statement now, on the same
  // connection, so the tic that starts next already has it.
  sendInputNow = INPUT_NOW ? () => {
    if (!running || ticInFlight > 2) return;
    pg.run([{ name: 'input', params: readCommand(stats.alive, false) }]).catch(() => {});
  } : null;
  // A cheat's message shows on the frame's message line (api_cheat_key puts
  // it there); idclev asks the host page for the map change.
  sendCheat = (ch) => pg.run([{ name: 'cheat', params: [ch] }]).then(([r]) => {
    const answer = r.rows[0] && r.rows[0][0];
    if (answer && answer.startsWith('warp:')) post('warp', { map: answer.slice(5) });
  }).catch(() => {});

  // ---- the render pool ----------------------------------------------------
  // Frames come from a pool of 1, 2, 4 or 6
  // Postgres connections with one frame in flight each, so up to N renders
  // run at once on N database cores. The host page picks N while playing
  // (postMessage action 'render_conns'). Input and game state stay on `pg`,
  // so they never wait behind a render.
  //  * api_camera goes in its own transaction (its own Sync), pipelined ahead
  //    of the frame. It updates the player's mp_players row; inside the
  //    frame's implicit transaction it would hold that row lock for the whole
  //    render, and parallel renders would run one at a time.
  //  * Requests are spread evenly, one every (average render time / N) and
  //    never faster than maxFps. Each carries a sequence number; a frame that
  //    arrives after a newer one is dropped instead of drawn.
  //  * Every render connection goes to the game's Lakebase endpoint (its
  //    branch), like `pg`.
  //  * Pipelined: each connection runs two request lanes, so
  //    the next camera + frame is already queued on the server when a frame
  //    finishes. Postgres runs them one after the other (still one render per
  //    connection and core), but it no longer idles for the network round
  //    trip, the transfer and the next request (~50 ms of each ~230 ms
  //    cycle, 2026-11-04). The camera runs right before its frame, so the
  //    pose is as fresh as before; pacing stays Little's law (round trip /
  //    lanes). localStorage.doomPipeline = '0' turns it off (A/B).
  const POOL_SIZES = [1, 2, 3, 4, 5, 6];   // the host's automatic pacing steps by one
  // Low-detail: the view renders only even screen columns (160 instead of
  // 320) for the 3D scene; the status bar stays at full width. The output is
  // 37 121 bytes (1 header + 168×160 + 32×320). We expand it to 64 001 bytes
  // (1 + 320×200) by doubling each scene pixel before blit(). Cost: <0.5 ms.
  const LOW_BYTES = 1 + 168 * 160 + 32 * 320;   // 37121
  let badSize = 0;   // frames of an unexpected size, dropped
  let framesPaused = false, framesPausedUntil = 0;   // loading screen (doomPauseFrames)
  const FULL_BYTES = 1 + 320 * 200;              // 64001
  function expandLow(src) {
    const dst = new Uint8Array(FULL_BYTES);
    dst[0] = src[0];                              // palette byte
    let si = 1, di = 1;
    for (let y = 0; y < 168; y++)                 // scene rows: double each pixel
      for (let c = 0; c < 160; c++) { dst[di++] = src[si]; dst[di++] = src[si++]; }
    const tail = 32 * 320;
    dst.set(src.subarray(si, si + tail), di);     // status bar: copy as-is
    return dst;
  }
  let poolTarget = 1;
  let poolChange = Promise.resolve();
  let avgRenderMs = 400;
  let seqIssued = 0, seqShown = 0, stale = 0;
  let poolWire = 0, poolWireMark = 0;
  let checking = false;
  const liveRenders = () => renderPool.filter((r) => !r.retired);
  const PIPELINE = localStorage.getItem('doomPipeline') === '0' ? 1 : 2;
  const liveLanes = () => liveRenders().reduce((n, r) => n + r.depth, 0);

  // ---- frame time breakdown: where a frame's browser time goes ------------
  //  camera  t0 -> api_camera answered (pipelined ahead of the frame on the
  //          same connection)
  //  first   t0 -> first byte of the frame on this connection
  //  db      the relay's own time for the same frames (Sync -> ReadyForQuery
  //          next to the database), sent back as {frame_ms} text frames
  //  net     first - db: browser <-> app network and proxy, both directions
  //  xfer    first byte -> last byte of the frame
  //  decode  parsing the last chunk (pgwire + delta XOR)
  //  wait    parsed -> the render loop resumes (main thread busy)
  //  gap     time between two frames drawn (what smoothness feels like)
  //  stall   longest main-thread stall (20 ms timer drift)
  const bd = { n: 0, cam: 0, first: 0, xfer: 0, decode: 0, wait: 0, db: 0, dbN: 0, relayRt: 0, relayRtN: 0, ping: 0, pingN: 0, pingKeep: null, gaps: [], stall: 0 };
  let lastBlitAt = 0;
  let stallTick = performance.now();
  // This code runs once per play(): the timer ends with the game.
  let stallSeenRunning = false;
  const stallTimer = setInterval(() => {
    const now = performance.now();
    if (!running) {
      if (stallSeenRunning) clearInterval(stallTimer);
      stallTick = now;
      return;
    }
    stallSeenRunning = true;
    bd.stall = Math.max(bd.stall, now - stallTick - 20);
    stallTick = now;
  }, 20);
  const instrument = (r) => {
    const ws = r.pg.ws, orig = ws.onmessage;
    ws.onmessage = (ev) => {
      const now = performance.now();
      if (typeof ev.data === 'string') {
        let m = null;
        try { m = JSON.parse(ev.data); } catch (e) { /* not ours */ }
        if (m && m.frame_ms !== undefined) {
          bd.db += m.frame_ms; bd.dbN++;
          const think = r.thinkQ.length ? r.thinkQ.shift() : null;
          if (typeof m.idle_ms === 'number' && think != null) { bd.relayRt += m.idle_ms - think; bd.relayRtN++; }
          return;
        }
        return orig.call(ws, ev);
      }
      const p = r.probes.find((x) => !x.done);   // the oldest request still answering
      if (p) {
        p.bytes += ev.data.byteLength;
        if (!p.first && p.bytes > 1024) p.first = now;   // the camera's answer is tiny
        p.last = now;
      }
      orig.call(ws, ev);
      if (p) p.parsed = performance.now();
    };
  };
  const pct = (a, q) => (a.length ? a.slice().sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor(a.length * q))] : null);

  // ---- one frame clock, frames handed out in turn ---------------------------
  // Every 1/maxFps s (35 a second) the clock hands one frame slot to the next
  // connection, in turn, that has a request lane free (r.depth per
  // connection). A slot no connection can take is counted ("pool full"):
  // the host's auto setting adds a connection on that, and takes one away
  // when fewer would do (host.js). Before 2026-11-19 every request paced
  // itself (average round trip / requests in flight), with no common clock.
  const waiting = new Map();          // connection -> lanes ready for a frame
  // A slot no lane can take is owed (at most 2) to the first lane that frees
  // up: a short stall (a slow answer, the network) then delays a frame
  // instead of losing it. Only a slot past those 2 counts as pool full, so
  // auto (host.js) grows on a real shortage, not on a stall (2026-11-19: on
  // 3 connections the owner saw pool full 6% and 31.4 frames/s; simulated
  // with 10% of answers stalled 150-250 ms on 2 connections: 30.3 -> 33.3
  // frames/s, pool full 11.8% -> 3.3%).
  let rr = 0, slots = 0, slotsFull = 0, owed = 0;
  const claimSlot = (r) => new Promise((resolve) => {
    if (owed > 0 && running && !r.retired) { owed--; resolve(); return; }
    if (!waiting.has(r)) waiting.set(r, []);
    waiting.get(r).push(resolve);
  });
  const dispatch = () => {
    for (const [r, q] of waiting) {
      if (r.retired || !running) { q.splice(0).forEach((go) => go()); waiting.delete(r); }
    }
    if (!running) return;
    slots++;
    const pool = liveRenders();
    for (let k = 0; k < pool.length; k++) {
      const q = waiting.get(pool[(rr + k) % pool.length]);
      if (q && q.length) { rr = (rr + k + 1) % pool.length; q.shift()(); return; }
    }
    if (owed < 2) owed++; else slotsFull++;
  };
  let clockAt = performance.now();
  const frameClock = () => {
    dispatch();
    if (!running) return;
    const interval = maxFps ? 1000 / maxFps : Math.max(5, avgRenderMs / Math.max(1, liveLanes()));
    clockAt = Math.max(clockAt + interval, performance.now() - interval);   // no burst after a stall
    setTimeout(frameClock, Math.max(0, clockAt - performance.now()));
  };

  const openRender = async () => {
    const renderUrl = `${proto}://${location.host}/pg?target=primary${guest ? '&guest=1' : ''}&tab=${doomTab}${doomGameQ}`;
    const r = { pg: new PgConnection(renderUrl, ['pg-delta']), retired: false, frameName: '', wireOut: 0, thinkQ: [], doneAt: 0,
      depth: PIPELINE, lanes: 0, outstanding: 0, probes: [], prep: null, prepFor: '' };
    r.pg.onclose = (err) => {
      renderPool = renderPool.filter((x) => x !== r);
      if (running && !r.retired && liveRenders().length === 0) {
        stop(`frame connections lost: ${err ? err.message : 'closed'}`, true);
      }
    };
    r.pg.onwire = (w) => { poolWire += w.wire_out - r.wireOut; r.wireOut = w.wire_out; };
    await r.pg.connect(guest ? { guest: true } : { user, password });
    instrument(r);
    // Coalesce: everything sent on this connection in one JS turn (the
    // camera's batch and the frame's) goes out as ONE WebSocket message.
    // Two back-to-back small messages can wait on Nagle / delayed ACK along
    // browser -> proxy -> app. localStorage.doomCoalesce = '0' turns it off
    // (for A/B in the breakdown row).
    if (localStorage.getItem('doomCoalesce') !== '0') {
      const rawSend = r.pg._send.bind(r.pg);
      let outq = null;
      r.pg._send = (bytes) => {
        if (!outq) {
          outq = [];
          queueMicrotask(() => {
            const q = outq; outq = null;
            if (q.length === 1) { rawSend(q[0]); return; }
            let n = 0; for (const b of q) n += b.length;
            const all = new Uint8Array(n); let o = 0;
            for (const b of q) { all.set(b, o); o += b.length; }
            rawSend(all);
          });
        }
        outq.push(bytes);
      };
      r.coalesce = true;
    }
    // Tiny probe for the breakdown: a small round trip on THIS connection.
    try { await r.pg.prepare('ping', 'SELECT 1', []); r.canPing = true; } catch (e) { r.canPing = false; }
    if (target !== 'primary') return r;   // read-only: camera and automap stay on pg
    await r.pg.prepare('camera', 'SELECT api_camera($1)', [OID.float8]);
    await r.pg.prepare('automap', 'SELECT api_automap()', []);
    await r.pg.prepare('am_pan', 'SELECT api_automap_pan($1,$2)', [OID.float8, OID.float8]);
    await r.pg.prepare('am_zoom', 'SELECT api_automap_zoom($1)', [OID.float8]);
    await r.pg.prepare('am_toggle', 'SELECT api_automap_toggle($1)', [OID.text]);
    await r.pg.prepare('am_fit', 'SELECT api_automap_fit()', []);
    return r;
  };

  // One connection, r.depth lanes; the last lane out closes it (a retired
  // connection finishes the frames it has in flight first).
  const renderLoop = (r) => {
    for (let i = 0; i < r.depth; i++) { r.lanes++; renderLane(r); }
  };

  // The frame statement, prepared once per connection even with two lanes.
  const ensurePrepared = async (r) => {
    if (r.frameName === frameName) return;
    if (r.prepFor !== frameName) {
      const name = frameName, sql = frameSql;
      r.prepFor = name;
      r.prep = r.pg.prepare(name, sql).then(() => { if (r.prepFor === name) r.frameName = name; },
                                            (err) => { if (r.prepFor === name) r.prepFor = ''; throw err; });
    }
    await r.prep;
  };

  const renderLane = async (r) => {
    while (running && !r.retired) {
      await claimSlot(r);
      if (!running || r.retired) break;
      if (!frameSql) { await sleep(100); continue; }
      if (framesPaused && performance.now() < framesPausedUntil) { await sleep(50); continue; }
      // Every 10th frame on this connection: a small ping right after the
      // last frame arrived, before the next request.
      r.iter = (r.iter || 0) + 1;
      if (r.canPing && r.iter % 10 === 0 && r.outstanding === 0) {
        const tp = performance.now();
        try { await r.pg.run([{ name: 'ping' }]); bd.ping += performance.now() - tp; bd.pingN++; } catch (e) { /* skip */ }
        r.doneAt = performance.now();   // the next request's think starts here
      }
      const mapUp = automap.on;
      const seq = ++seqIssued;
      const alpha = INTERPOLATE ? Math.min(1, Math.max(0, (performance.now() - lastTic) / TIC_MS)) : 1;
      const t0 = performance.now();
      // Browser-side time between the last answer and this request; the relay
      // reports its idle time over the same span, the difference is the
      // network round trip on this connection.
      // One entry per request; the relay's {frame_ms, idle_ms} for that
      // request takes it off (it can arrive after the next request left).
      // (a pipelined request has no think time: the relay was not idle)
      r.thinkQ.push(r.doneAt && r.outstanding === 0 ? t0 - r.doneAt : null);
      let frame, camAt = 0;
      const probe = { bytes: 0, first: 0, last: 0, parsed: 0, done: false };
      r.probes.push(probe);
      r.outstanding++;
      try {
        if (!mapUp) await ensurePrepared(r);
        // Two batches, two Syncs: the camera commits on its own. Both go down
        // the same connection (one round trip).
        const writer = r.pg;
        const cam = writer.run([{ name: 'camera', params: [alpha] }]);
        const pending = mapUp ? amPending.splice(0, amPending.length) : [];
        const req = mapUp ? writer.run([...pending, { name: 'automap', binary: true, params: [] }])
                          : r.pg.run([{ name: r.frameName, binary: true }]);
        req.catch(() => {});
        await cam;
        camAt = performance.now();
        const result = await req;
        const last = result[result.length - 1];
        frame = last && last.rows[0] && last.rows[0][0];
      } catch (err) {
        r.outstanding--;
        probe.done = true; r.probes = r.probes.filter((x) => x !== probe);
        if (!running || r.retired) break;
        r.thinkQ = [];   // no answer, no relay timing: start pairing afresh
        console.warn('frame dropped:', err.message);
        await sleep(50);
        continue;
      }
      const doneAt = performance.now();
      r.outstanding--;
      probe.done = true; r.probes = r.probes.filter((x) => x !== probe);
      // A pipelined request waited behind the previous one: its own time
      // starts when that one's last byte arrived (answers come in order).
      const start = Math.max(t0, r.doneAt || 0);
      r.doneAt = probe.last || doneAt;
      const ms = doneAt - t0;               // round trip incl. queue: pacing
      const svc = doneAt - start;           // this frame's own time: display
      avgRenderMs = avgRenderMs * 0.8 + ms * 0.2;
      if (frame && !mapUp && probe.first) {
        bd.n++;
        bd.cam += Math.max(0, camAt - start);
        bd.first += Math.max(0, probe.first - start);
        bd.xfer += probe.last - probe.first;
        bd.decode += probe.parsed - probe.last;
        bd.wait += doneAt - probe.parsed;
      }
      if (!frame) {
        // Either the slot was handed back, or the match moved to another map
        // and the view for this slot was rebuilt: ask which (one at a time).
        if (checking) { await sleep(100); continue; }
        checking = true;
        try {
          let held = -1;
          try {
            const [sl, m] = await pg.run([{ name: 'slot' }, { name: 'match' }]);
            held = parseInt(sl.rows[0][0], 10); readMatch(m.rows[0]);
          } catch (e) { /* ask again */ }
          if (held !== slot) {
            const held_for = (performance.now() - joinedAt) / 1000;
            const turn = match.hold > 0 && match.waiting > 0 && held_for >= match.hold - 5;
            stop(turn ? `your ${Math.round(match.hold / 60)} minutes are up and someone is waiting; press Play to queue again`
                      : 'the server took the slot back (idle too long?)', !turn);
            return;
          }
          if (frameMap !== match.mapId) prepareFrame();
        } finally {
          checking = false;
        }
        await sleep(100);
        continue;
      }
      if (seq < seqShown) { stale++; continue; }
      // Indexed frames are exactly 64001 (full) or 37121 (low detail) bytes.
      // Any other size would be drawn as garbage (e.g. a 160-wide picture
      // shown twice side by side), so drop it and keep the previous picture.
      if (!mapUp && frame && frame.length !== LOW_BYTES && frame.length !== 1 + W * H) {
        if (!badSize++) console.warn(`[render] dropped frame of ${frame.length} bytes`);
        continue;
      }
      seqShown = seq;
      if (frame && frame.length === LOW_BYTES) frame = expandLow(frame);
      if (mapUp) blitRGB(frame); else blit(frame, lut);
      { const now = performance.now(); if (lastBlitAt) bd.gaps.push(now - lastBlitAt); lastBlitAt = now; }
      stats.frames++; stats.bytes += frame.length; stats.rtt += svc;
      const elapsed = performance.now() - stats.since;
      if (elapsed >= 1000) {
        const clock = match.left >= 0 ? ` · ${match.map} ${Math.floor(match.left / 60)}:${String(match.left % 60).padStart(2, '0')} left` : ` · ${match.map}`;
        const ticMs = stats.tics ? stats.ticRtt / stats.tics : 0;
        const wireKbps = poolWire > poolWireMark ? (poolWire - poolWireMark) / (elapsed / 1000) : null;
        poolWireMark = poolWire;
        const conns = liveRenders().length;
        const coding = renderPool[0] && renderPool[0].pg.delta ? 'delta+deflate' : 'deflate';
        ui.stats.textContent = `${(stats.frames * 1000 / elapsed).toFixed(1)} fps · `
          + `${(stats.rtt / stats.frames).toFixed(1)} ms/frame · ${conns} frame${conns === 1 ? '' : 's'} in flight · ${ticMs.toFixed(0)} ms/tic · `
          + `${(stats.bytes / elapsed).toFixed(0)} KB/s before ${coding}`
          + `${wireKbps === null ? '' : ` → ${(wireKbps / 1024).toFixed(0)} KB/s on the wire`} · `
          + `${stats.frags} frags · ${stats.health} hp${clock}`;
        post('stats', {
          text: ui.stats.textContent,
          fps: stats.frames * 1000 / elapsed,
          msPerFrame: stats.rtt / stats.frames,
          ticMs,
          kbps: stats.bytes / elapsed,
          wireKbps: wireKbps === null ? null : wireKbps / 1024,
          frags: stats.frags,
          health: stats.health,
          coding,
          renderConns: conns,
          // share of the frame clock's slots no connection could take
          poolFull: slots ? slotsFull / slots : null,
          stale,
          breakdown: bd.n ? {
            frames: bd.n,
            camera: bd.cam / bd.n,
            first: bd.first / bd.n,
            db: bd.dbN ? bd.db / bd.dbN : null,
            net: bd.dbN ? bd.first / bd.n - bd.db / bd.dbN : null,
            xfer: bd.xfer / bd.n,
            decode: bd.decode / bd.n,
            wait: bd.wait / bd.n,
            relayRt: bd.relayRtN ? bd.relayRt / bd.relayRtN : null,
            ping: bd.pingN ? bd.ping / bd.pingN : bd.pingKeep,
            lowDetail,
            coalesce: !!(renderPool[0] && renderPool[0].coalesce),
            // the browser's own switches (localStorage, kept per browser):
            // a leftover A/B setting shows up in Copy stats
            pipeline: PIPELINE,
            interpolate: INTERPOLATE,
            inputNow: INPUT_NOW,
            changed: [
              PIPELINE !== 2 && 'doomPipeline',
              INTERPOLATE && 'doomInterp',
              !INPUT_NOW && 'doomInputNow',
              !(renderPool[0] && renderPool[0].coalesce) && 'doomCoalesce',
            ].filter(Boolean),
            gapP50: pct(bd.gaps, 0.5),
            gapMax: pct(bd.gaps, 1),
            stall: bd.stall,
          } : null,
        });
        // pings are sparse (every 10th frame): keep the last value shown
        Object.assign(bd, { pingKeep: bd.pingN ? bd.ping / bd.pingN : bd.pingKeep });
        Object.assign(bd, { n: 0, cam: 0, first: 0, xfer: 0, decode: 0, wait: 0, db: 0, dbN: 0, relayRt: 0, relayRtN: 0, ping: 0, pingN: 0, gaps: [], stall: 0 });
        stats.frames = 0; stats.bytes = 0; stats.rtt = 0; stats.tics = 0; stats.ticRtt = 0; stale = 0;
        slots = 0; slotsFull = 0;
        stats.since = performance.now();
        pg.run([{ name: 'score' }, { name: 'match' }]).then(([sc, m]) => {
          renderScore(sc.rows, user); readMatch(m.rows[0]);
          // the host page's scoreboard card
          post('score', { rows: sc.rows, match: m.rows[0], user });
        }).catch(() => {});
      }
    }
    // Retired (the pool shrank) or the game ended: the last lane closes.
    if (--r.lanes > 0) return;
    renderPool = renderPool.filter((x) => x !== r);
    try { r.pg.close(); } catch (e) { /* */ }
  };

  // Grow by opening connections one after another; shrink by retiring the
  // newest ones, each after its frame in flight. Changes queue up in order.
  const resizePool = (n) => {
    poolTarget = POOL_SIZES.includes(n) ? n : 1;
    poolChange = poolChange.then(async () => {
      while (running && liveRenders().length < poolTarget) {
        let r;
        try {
          r = await openRender();
        } catch (err) {
          if (liveRenders().length === 0) { stop(`could not open a render connection: ${err.message}`, true); return; }
          status(`could not open another render connection: ${err.message}`, true);
          break;
        }
        if (!running) { try { r.pg.close(); } catch (e) { /* */ } return; }
        renderPool.push(r);
        renderLoop(r);
      }
      for (const r of liveRenders().slice(poolTarget)) r.retired = true;
      const live = liveRenders();
      post('render_conns', { n: live.length });
    });
    return poolChange;
  };
  window.doomSetRenderConns = (n) => { if (running) resizePool(n); };
  // Loading screen between two maps (host.js showBetween): no new frame
  // requests while it is up, so the referee's VACUUM FULL finds the tables
  // free (frames in flight finish; it waits for them). At most 15 s, in
  // case the host never says it is over.
  window.doomPauseFrames = (on) => {
    framesPaused = !!on;
    framesPausedUntil = on ? performance.now() + 15000 : 0;
  };
  // Low detail on/off (page-level lowDetail already set): a new statement
  // name makes every render connection prepare the other view on its next frame.
  window.doomSetLowDetail = () => {
    if (!running || frameMap < 0) return;
    frameName = `frame${++frameGen}`;
    frameSql = `SELECT frame_rgb FROM api_frame_idx_slot${slot}_m${frameMap}${lowDetail ? '_low' : ''}`;
  };
  resizePool(renderConns);
  frameClock();

  const stop = (why, bad) => {
    if (!running) return;
    sendInputNow = null;
    sendCheat = null;
    running = false;
    clearInterval(ticker);
    if (audio) { audio.stopAll(); audio.stopMusic(); }
    if (document.pointerLockElement) document.exitPointerLock();
    ui.stage.classList.remove('live');
    ui.overlay.hidden = true;
    ui.help.hidden = true;
    ui.button.disabled = false;
    status(why, bad);
    post('state', { state: 'stopped' });
    try { pg.close(); } catch (e) { /* */ }
    for (const r of renderPool) { r.retired = true; try { r.pg.close(); } catch (e) { /* */ } }
    renderPool = [];
  };
  window.doomStop = stop;
  // A tab in the background would keep pulling frames nobody sees and hold a
  // seat someone else could have. Leave instead; Play brings you back.
  const onVisibility = () => {
    if (document.hidden && running) {
      document.removeEventListener('visibilitychange', onVisibility);
      stop('left the game: the tab went to the background', false);
    }
  };
  document.addEventListener('visibilitychange', onVisibility);
}

function renderScore(rows, me) {
  const ordered = [...rows].sort((a, b) => parseInt(a[0], 10) - parseInt(b[0], 10));
  ui.score.innerHTML = '<h2>DEATHMATCH</h2>' + ordered.map(([slot, role, connected, frags, health, alive, login]) => {
    const who = connected === 't' ? role : '<em>free</em>';
    const you = login === me ? ' (you)' : '';
    const state = connected === 't' ? `${frags} frags · ${health} hp${alive === 't' ? '' : ' · dead'}` : '';
    return `<div class="row"><span class="slot">${slot}</span><span class="who">${who}${you}</span><span class="state">${state}</span></div>`;
  }).join('');
}

// ------------------------------------------------------------------- setup
async function setup() {
  try {
    const cfg = await (await fetch('config.json')).json();
    ui.target.innerHTML = cfg.targets.map((t) => `<option value="${t}">${t}</option>`).join('');
    // One server to pick from is no choice; show the field only when there are several.
    ui.targetField.hidden = cfg.targets.length < 2;
    clientParallel = cfg.parallel || null;
    guestSeats = cfg.guests || 0;
    if (typeof cfg.max_fps === 'number') maxFps = Math.max(0, cfg.max_fps);
    if ([1, 2, 3, 4, 5, 6].includes(cfg.render_conns)) renderConns = cfg.render_conns;
  } catch (e) {
    ui.target.innerHTML = '<option value="127.0.0.1:5720">127.0.0.1:5720</option>';
  }
  // Without guest seats the page is the account form; with them the account
  // form hides behind a link.
  const showAccount = (on) => {
    accountMode = on;
    ui.userField.hidden = !on; ui.passwordField.hidden = !on;
    ui.user.required = on; ui.password.required = on;
    ui.button.textContent = on ? 'JOIN' : 'PLAY';
    ui.accountToggle.textContent = on ? 'play as a guest instead' : 'sign in with a player account';
    ui.accountToggle.hidden = guestSeats === 0;
  };
  showAccount(guestSeats === 0);
  ui.accountToggle.addEventListener('click', (ev) => { ev.preventDefault(); showAccount(!accountMode); });
  const params = new URLSearchParams(location.search);
  if (params.get('user')) ui.user.value = params.get('user');
  if (params.get('target')) ui.target.value = params.get('target');
  if (params.get('nick')) ui.nick.value = params.get('nick').slice(0, 12);
  const start = async (user, password, nick, guest) => {
    ui.button.disabled = true;
    post('state', { state: 'connecting' });
    try {
      await play(user, password, ui.target.value, nick, guest);
    } catch (err) {
      running = false;
      ui.button.disabled = false;
      status(`could not join: ${err.message}`, true);
      post('state', { state: 'stopped' });
      if (pg) { try { pg.close(); } catch (e) { /* */ } }
      for (const r of renderPool) { try { r.pg.close(); } catch (e) { /* */ } }
      renderPool = [];
    }
  };
  ui.form.addEventListener('submit', (ev) => {
    ev.preventDefault();
    start(ui.user.value.trim(), ui.password.value, ui.nick.value.trim(), !accountMode);
  });
  // Embedded in another page (?embed=1 inside an iframe): the page is just
  // the screen. The host draws the form and asks us to play or stop; we tell
  // it what the status and stats lines would have said.
  embedded = params.get('embed') === '1' && window.parent !== window;
  if (embedded) {
    document.body.classList.add('embed');
    window.addEventListener('message', (ev) => {
      const m = ev.data;
      if (!m || m.source !== 'sqldoom-host') return;
      if (m.action === 'play' && !running && !ui.button.disabled) {
        const nick = String(m.nick || '').slice(0, 12).trim();
        if (m.user) start(String(m.user), String(m.password || ''), nick, false);
        else start('', '', nick, true);
      }
      if (m.action === 'stop' && window.doomStop) window.doomStop('left the game', false);
      if (m.action === 'render_conns') {
        const n = parseInt(m.n, 10);
        if ([1, 2, 3, 4, 5, 6].includes(n)) { renderConns = n; if (window.doomSetRenderConns) window.doomSetRenderConns(n); }
      }
      // loading screen between two maps: no frame requests while it is up
      if (m.action === 'frames_pause' && window.doomPauseFrames) window.doomPauseFrames(!!m.on);
      if (m.action === 'cheats') cheatsOn = !!m.on;
      if (m.action === 'always_run') alwaysRun = !!m.on;
      if (m.action === 'music') {
        musicOn = !!m.on;
        if (window.doomMusic) window.doomMusic();
      }
      // page-level handler: play()'s variables are reached through doomSetLowDetail
      if (m.action === 'low_detail') {
        lowDetail = !!m.on;
        if (window.doomSetLowDetail) window.doomSetLowDetail();
      }
    });
    post('ready', { guests: guestSeats, targets: ui.target.options.length });
  }
}

setup();
