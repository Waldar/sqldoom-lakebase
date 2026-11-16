"""Patches the upstream SQLDoom page (sqldoom/web/app.js) in memory.

The Git folder stays untouched; app.py serves the result at /upstream/app.js.
What changes:
  * the frame loop is replaced by render_pool.js: a pool of 1, 2, 4 or 6
    render connections, two requests pipelined on each (one on replicas),
    camera in its own transaction, frames sequenced; input and game state
    stay on `pg`
  * the frame statement is prepared by each render connection (frameSql)
  * config.json's render_conns sets the initial pool size; the host page
    resizes it live with postMessage {action: 'render_conns', n}
  * the host page moves the pool between endpoints with {action:
    'render_target', target} (stage 1 'primary', stage 2 'replica': the
    pool spreads over config.json's replica1..N); on a replica the camera
    and automap writes go to the primary
  * stop() and the join error path close the pool

Every anchor must be found exactly once, or patch() raises and app.py falls
back to the unpatched page (so an upstream change cannot half-apply).
"""
from pathlib import Path

POOL_JS = Path(__file__).resolve().parent / "render_pool.js"
FRAME_START = "  // Frames: as fast as the database answers."
FRAME_END = "  for (let i = 0; i < FRAMES_IN_FLIGHT; i++) frameLoop();\n"
POOL_SIZES = (1, 2, 3, 4, 5, 6)   # 3 and 5: the page's automatic pacing steps one at a time


def _sub(src, old, new):
    n = src.count(old)
    if n != 1:
        raise ValueError(f"app.js anchor found {n} times, expected 1: {old[:70]!r}")
    return src.replace(old, new, 1)


def patch(src: str) -> str:
    src = _sub(src, "let pg = null;",
               "let pg = null;\nlet renderPool = [];   // patched: the frame connections (render_pool.js)\n"
               "// patched: this browser tab's player token. The relay plays each tab as\n"
               "// <signed-in user>#<token>, so two tabs are two players; every connection\n"
               "// of the tab (control + render pool) sends the same token.\n"
               "const doomTab = (() => {\n"
               "  let t = '';\n"
               "  try { t = sessionStorage.getItem('sqldoom.tab') || ''; } catch (e) { /* */ }\n"
               "  if (!/^[a-z0-9]{1,12}$/.test(t)) {\n"
               "    t = Math.random().toString(36).slice(2, 10) || 'tab';\n"
               "    try { sessionStorage.setItem('sqldoom.tab', t); } catch (e) { /* */ }\n"
               "  }\n"
               "  return t;\n"
               "})();\n"
               "// patched: the game this page plays (one Lakebase branch per game,\n"
               "// doomapp/games.py), from the embed URL ?game=<id>; empty = the shared match.\n"
               "const doomGame = (new URLSearchParams(location.search).get('game') || '').replace(/[^a-f0-9]/g, '').slice(0, 16);\n"
               "const doomGameQ = doomGame ? `&game=${doomGame}` : '';")
    src = _sub(src, "${guest ? '&guest=1' : ''}`;\n  pg = new PgConnection(url, ['pg-delta']);",
               "${guest ? '&guest=1' : ''}&tab=${doomTab}${doomGameQ}`;   // patched: per-tab player, per-game branch\n  pg = new PgConnection(url, ['pg-delta']);")
    src = _sub(src, "let maxFps = 35;",
               "let maxFps = 35;\nlet renderConns = 4;   // patched: render pool size, 1, 2, 4 or 6\n"
               "let renderTarget = 'primary';   // patched: endpoint the render pool uses (stage)\n"
               "let renderTargets = ['primary'];   // patched: endpoints config.json offers\n"
               "let lowDetail = false;   // patched: low-detail frames (160 scene columns, doubled in JS)")
    src = _sub(src, "let frameGen = 0, frameName = '', frameMap = -1;",
               "let frameGen = 0, frameName = '', frameMap = -1, frameSql = '';")
    src = _sub(src,
               "    await pg.prepare(frameName, `SELECT frame_rgb FROM api_frame_idx_slot${slot}_m${match.mapId}`);",
               "    frameSql = `SELECT frame_rgb FROM api_frame_idx_slot${slot}_m${match.mapId}${lowDetail ? '_low' : ''}`;   // patched: each render connection prepares it")
    # The frame loop, from its comment to the line that starts it.
    if src.count(FRAME_START) != 1 or src.count(FRAME_END) != 1:
        raise ValueError("app.js frame loop anchors not found exactly once")
    i = src.index(FRAME_START)
    j = src.index(FRAME_END, i) + len(FRAME_END)
    src = src[:i] + POOL_JS.read_text() + src[j:]
    # stop(): close the pool with the control connection.
    src = _sub(src, "    try { pg.close(); } catch (e) { /* */ }\n  };",
               "    try { pg.close(); } catch (e) { /* */ }\n"
               "    for (const r of renderPool) { r.retired = true; try { r.pg.close(); } catch (e) { /* */ } }\n"
               "    renderPool = [];\n  };")
    src = _sub(src, "      if (pg) { try { pg.close(); } catch (e) { /* */ } }",
               "      if (pg) { try { pg.close(); } catch (e) { /* */ } }\n"
               "      for (const r of renderPool) { try { r.pg.close(); } catch (e) { /* */ } }\n"
               "      renderPool = [];")
    # Initial size from config.json; live changes from the host page.
    src = _sub(src, "    if (typeof cfg.max_fps === 'number') maxFps = Math.max(0, cfg.max_fps);",
               "    if (typeof cfg.max_fps === 'number') maxFps = Math.max(0, cfg.max_fps);\n"
               "    if ([1, 2, 3, 4, 5, 6].includes(cfg.render_conns)) renderConns = cfg.render_conns;\n"
               "    if (Array.isArray(cfg.targets) && cfg.targets.length) renderTargets = cfg.targets.map(String);")
    src = _sub(src, "      if (m.action === 'stop' && window.doomStop) window.doomStop('left the game', false);",
               "      if (m.action === 'stop' && window.doomStop) window.doomStop('left the game', false);\n"
               "      if (m.action === 'render_conns') {\n"
               "        const n = parseInt(m.n, 10);\n"
               "        if ([1, 2, 3, 4, 5, 6].includes(n)) { renderConns = n; if (window.doomSetRenderConns) window.doomSetRenderConns(n); }\n"
               "      }\n"
               "      // loading screen between two maps: no frame requests while it is up\n"
               "      if (m.action === 'frames_pause' && window.doomPauseFrames) window.doomPauseFrames(!!m.on);\n"
               "      // page-level handler: play()'s variables are reached through doomSetLowDetail\n"
               "      if (m.action === 'low_detail') {\n"
               "        lowDetail = !!m.on;\n"
               "        if (window.doomSetLowDetail) window.doomSetLowDetail();\n"
               "      }\n"
               "      // 'primary' (stage 1) or 'replica' (stage 2: the pool spreads over replica1..N)\n"
               "      if (m.action === 'render_target' && (m.target === 'primary'\n"
               "          || (m.target === 'replica' && renderTargets.some((t) => t.startsWith('replica'))))) {\n"
               "        renderTarget = m.target;\n"
               "        if (window.doomSetRenderTarget) window.doomSetRenderTarget(renderTarget);\n"
               "      }")
    # Game modes (doomapp/referee.py): during a mode switch api_match.next_map
    # is DEATHMATCH (countdown), FINAL (deathmatch over: the host page offers
    # stay / single player), SINGLE PLAYER or RESTART (single-player death or
    # new rules: the same map again), instead of a map name.
    src = _sub(src, "      ui.overlayText.textContent = `${match.map} COMPLETE \u2014 ${match.next} IN ${match.seconds} s`;",
               "      ui.overlayText.textContent = match.next === 'DEATHMATCH'   // patched: game modes\n"
               "        ? `DEATHMATCH STARTS IN ${match.seconds}`\n"
               "        : match.next === 'FINAL'\n"
               "          ? `DEATHMATCH OVER \u2014 STAY OR GO SOLO? SINGLE PLAYER IN ${match.seconds} s`\n"
               "          : match.next === 'SINGLE PLAYER'\n"
               "            ? `SINGLE PLAYER STARTS IN ${match.seconds}`\n"
               "            : match.next === 'RESTART'\n"
                "              ? `LEVEL RESTARTS IN ${match.seconds}`\n"
                "              : `${match.map} COMPLETE \u2014 ${match.next} IN ${match.seconds} s`;")
    return src
