  // ---- patched for Lakebase (doomapp/render_pool.js) ----------------------
  // Replaces the upstream frame loop. Frames come from a pool of 1, 2, 4 or 6
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
  //  * The pool renders on renderTarget: 'primary' (stage 1), or 'replica'
  //    (stage 2): the read replicas replica1..N from config.json. On replicas
  //    each new connection goes to the replica with the fewest, so they are
  //    spread round robin. Overlapping renders on one replica stall its WAL
  //    replay (hot standby snapshot conflicts), so the page never asks for
  //    more connections than there are replicas. A replica cannot write, so
  //    there the camera and the automap run on the primary's `pg`, and the
  //    frame reads the pose once it has replicated. The host page switches
  //    the target live (action 'render_target'): the pool is rebuilt on it.
  //  * Pipelined: on the primary each connection runs two request lanes, so
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
  const groupOf = (t) => (t === 'primary' ? 'primary' : 'replica');
  const endpointsFor = (group) => (group === 'primary' ? ['primary']
    : renderTargets.filter((t) => t.startsWith('replica')));
  // Least-loaded endpoint of the group: round robin as the pool grows, and
  // it refills the gap a retired connection leaves.
  const pickEndpoint = (group) => {
    const eps = endpointsFor(group);
    if (!eps.length) return null;
    const load = (t) => liveRenders().filter((r) => r.target === t).length;
    return eps.reduce((best, t) => (load(t) < load(best) ? t : best), eps[0]);
  };
  let poolTarget = 1;
  let poolChange = Promise.resolve();
  let nextFrameAt = performance.now();
  let avgRenderMs = 400;
  let seqIssued = 0, seqShown = 0, stale = 0;
  let poolWire = 0, poolWireMark = 0;
  let checking = false;
  const liveRenders = () => renderPool.filter((r) => !r.retired);
  const PIPELINE = localStorage.getItem('doomPipeline') === '0' ? 1 : 2;
  const liveLanes = () => liveRenders().reduce((n, r) => n + r.depth, 0);

  // ---- frame time breakdown: where a frame's browser time goes ------------
  //  camera  t0 -> api_camera answered (pipelined ahead of the frame on the
  //          primary; on replicas it runs on `pg`, concurrently)
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

  const pace = async () => {
    const interval = Math.max(maxFps ? 1000 / maxFps : 0, avgRenderMs / Math.max(1, liveLanes()));
    const now = performance.now();
    const at = Math.max(now, nextFrameAt);
    nextFrameAt = at + interval;
    if (at > now) await sleep(at - now);
  };

  const openRender = async () => {
    const target = pickEndpoint(renderTarget);
    if (!target) throw new Error(`no endpoint configured for ${renderTarget}`);
    const renderUrl = `${proto}://${location.host}/pg?target=${encodeURIComponent(target)}${guest ? '&guest=1' : ''}&tab=${doomTab}${doomGameQ}`;
    // Replicas keep one request at a time (see above: no overlap there).
    const r = { pg: new PgConnection(renderUrl, ['pg-delta']), target, group: groupOf(target), retired: false, frameName: '', wireOut: 0, thinkQ: [], doneAt: 0,
      depth: target === 'primary' ? PIPELINE : 1, lanes: 0, outstanding: 0, probes: [], prep: null, prepFor: '' };
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
    try { await r.pg.query('SET async_commit = on'); } catch (e) { /* not every server has it */ }
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
      await pace();
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
      const alpha = Math.min(1, Math.max(0, (performance.now() - lastTic) / TIC_MS));
      const t0 = performance.now();
      // Browser-side time between the last answer and this request; the relay
      // reports its idle time over the same span, the difference is the
      // network round trip on this connection.
      // One entry per request; the relay's {frame_ms, idle_ms} for that
      // request takes it off (it can arrive after the next request left).
      // (on a replica the automap answer comes back on pg, not here)
      // (a pipelined request has no think time: the relay was not idle)
      if (!(automap.on && r.target !== 'primary')) r.thinkQ.push(r.doneAt && r.outstanding === 0 ? t0 - r.doneAt : null);
      let frame, camAt = 0;
      const probe = { bytes: 0, first: 0, last: 0, parsed: 0, done: false };
      r.probes.push(probe);
      r.outstanding++;
      try {
        if (!mapUp) await ensurePrepared(r);
        // Two batches, two Syncs: the camera commits on its own. On the
        // primary both go down the same connection (one round trip); on a
        // replica the camera and the automap go to the primary's pg.
        const writer = r.target === 'primary' ? r.pg : pg;
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
            gapP50: pct(bd.gaps, 0.5),
            gapMax: pct(bd.gaps, 1),
            stall: bd.stall,
          } : null,
        });
        // pings are sparse (every 10th frame): keep the last value shown
        Object.assign(bd, { pingKeep: bd.pingN ? bd.ping / bd.pingN : bd.pingKeep });
        Object.assign(bd, { n: 0, cam: 0, first: 0, xfer: 0, decode: 0, wait: 0, db: 0, dbN: 0, relayRt: 0, relayRtN: 0, ping: 0, pingN: 0, gaps: [], stall: 0 });
        stats.frames = 0; stats.bytes = 0; stats.rtt = 0; stats.tics = 0; stats.ticRtt = 0; stale = 0;
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
      while (running && liveRenders().filter((r) => r.group === groupOf(renderTarget)).length < poolTarget) {
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
      post('render_conns', { n: live.length, targets: live.map((r) => r.target) });
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
  // Move the pool to another endpoint: retire every render connection (each
  // after its frame in flight) and open the same number on the new target.
  window.doomSetRenderTarget = (t) => {
    if (!running) return;
    for (const r of liveRenders()) if (r.group !== groupOf(t)) r.retired = true;
    resizePool(poolTarget);
  };
  resizePool(renderConns);
