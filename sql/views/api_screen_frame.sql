-- Single player's screens between levels (2026-11-21), in the frame views'
-- format: one palette byte (0), then 320 x 200 palette indices, row by row.
-- The app's frame threads read it instead of the player's view while the
-- referee runs the screens (sqldoom/server/frames.py, Metrics.screen); NULL
-- outside them. What it draws follows screen_state (doom_solo_level_end,
-- doom_solo_screen_tic):
--   the intermission's stats   WI_drawStats: WIMAP0, the level's name and
--                              FINISHED, kills / items / secrets as they
--                              count up, time and par
--   the episode map            WI_drawShowNextLoc: a splat on every level
--                              done (and E1M9 once played), the blinking
--                              arrow on the next, ENTERING and its name
--   the episode's end          F_TextWrite: the flat tiled, the text typed a
--                              letter every 3 tics; then the picture (HELP2
--                              in the shareware game, F_Drawer)
-- Positions are wi_stuff.c's and f_finale.c's (SP_STATSX 50, SP_TIMEX 16,
-- lnodes of episode 1, ...). The animated parts of the episode maps (WIA*)
-- are not loaded and not drawn.
CREATE OR REPLACE VIEW doom.api_screen_frame AS
WITH s AS MATERIALIZED (
  SELECT ss.screen::text AS screen, ss.inter_episode AS ep, ss.inter_level AS lv, ss.inter_next AS nx,
         ss.sp_state AS st, ss.cnt_pause AS cnt,
         ss.kills_pct AS k, ss.items_pct AS i, ss.secrets_pct AS sc, ss.time_secs AS t, ss.par_secs AS p,
         ss.did_secret, ss.finale_episode AS fep, ss.finale_count AS fc, ss.finale_stage AS fst,
         ss.tics AS bcnt, ss.anim_base, ss.anim_rnd
  FROM screen_state ss
  WHERE ss.id = 0 AND ss.screen IN ('intermission', 'finale')
),
pw AS (
  SELECT p.name, p.width, p.height, p.left_offset, p.top_offset FROM ui_patches p
),
-- wi_stuff.c lnodes[0]: where each level of episode 1 is on WIMAP0
lnode (n, x, y) AS (
  VALUES (0, 185, 164), (1, 148, 143), (2, 69, 122), (3, 209, 102), (4, 116, 89),
         (5, 166, 55), (6, 71, 56), (7, 135, 29), (8, 71, 24)
),
stats AS (
  SELECT * FROM s WHERE s.screen = 'intermission' AND s.st <= 10
),
nextloc AS (
  SELECT * FROM s WHERE s.screen = 'intermission' AND s.st > 10
),
-- wi_stuff.c epsd0animinfo: episode 1's ten moving parts, three frames each
-- every TICRATE / 3 (11 tics), patches WIA0<anim><frame> (2026-11-21)
anim_loc (j, x, y) AS (
  VALUES (0, 224, 104), (1, 184, 160), (2, 112, 136), (3, 72, 112), (4, 88, 96),
         (5, 64, 48), (6, 192, 40), (7, 136, 16), (8, 80, 16), (9, 64, 24)
),
-- WI_updateAnimatedBack: an animation's first frame at anim_base + 1 + its
-- random start, the next every 11 tics, round and round; WI_drawAnimatedBack
-- draws it (nothing before its first frame)
anims AS (
  SELECT 'WIA0' || lpad(a.j::text, 2, '0') || lpad((((s.bcnt - a.start) / 11) % 3)::text, 2, '0') AS name,
         a.x, a.y
  FROM s
  CROSS JOIN LATERAL (SELECT l.j, l.x, l.y, s.anim_base + 1 + COALESCE(s.anim_rnd[l.j + 1], 0) AS start
                      FROM anim_loc l) a
  WHERE s.screen = 'intermission' AND s.ep = 1 AND s.bcnt >= a.start
),
-- the figures shown so far (-1: not yet), right edge x and line y
nums AS (
  SELECT v.val, v.x, v.y, v.kind
  FROM stats st
  CROSS JOIN LATERAL (VALUES (st.k, 270, 50, 'pct'), (st.i, 270, 68, 'pct'), (st.sc, 270, 86, 'pct'),
                             (st.t, 144, 168, 'time'), (st.p, 304, 168, 'time')) v(val, x, y, kind)
  WHERE v.val >= 0
),
-- F_TextWrite: the text typed so far, from (10, 10), 11 pixels a line,
-- 4 pixels for a character the font lacks (a space)
chars AS (
  SELECT g.i, substr(f.story_text, g.i, 1) AS ch
  FROM s
  JOIN finale_defs f ON f.episode = s.fep
  CROSS JOIN LATERAL generate_series(1, LEAST(length(f.story_text), GREATEST(0, (s.fc - 10) / 3))) g(i)
  WHERE s.screen = 'finale' AND s.fst = 0
),
glyph_adv AS (
  SELECT c.i, c.ch = E'\n' AS nl, p.name AS glyph,
         CASE WHEN c.ch = E'\n' THEN 0 ELSE COALESCE(p.width, 4) END AS w,
         SUM(CASE WHEN c.ch = E'\n' THEN 1 ELSE 0 END) OVER (ORDER BY c.i) AS line
  FROM chars c
  LEFT JOIN pw p ON ascii(upper(c.ch)) BETWEEN 33 AND 95
                AND p.name = 'STCFN' || lpad(ascii(upper(c.ch))::text, 3, '0')
),
glyphs AS (
  SELECT ga.glyph, ga.w, 10 + 11 * ga.line::int AS cy,
         10 + COALESCE(SUM(ga.w) OVER (PARTITION BY ga.line ORDER BY ga.i
                                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)::int AS cx
  FROM glyph_adv ga
),
-- every patch drawn, in V_DrawPatch's coordinates (before the patch's
-- offsets); z: a later layer covers an earlier one
layers AS (
  -- WI_drawAnimatedBack, under everything else (drawn right after the background)
  SELECT 0 AS z, an.name, an.x, an.y FROM anims an
  UNION ALL
  -- WI_drawLF: the finished level's name, centred, FINISHED under it
  SELECT 1, ln.name, (320 - ln.width) / 2, 2
  FROM stats st JOIN pw ln ON ln.name = 'WILV' || (st.ep - 1)::text || (st.lv - 1)::text
  UNION ALL
  SELECT 1, f.name, (320 - f.width) / 2, 2 + (5 * ln.height) / 4
  FROM stats st JOIN pw ln ON ln.name = 'WILV' || (st.ep - 1)::text || (st.lv - 1)::text
  JOIN pw f ON f.name = 'WIF'
  UNION ALL
  -- WI_drawStats: the labels
  SELECT 1, v.name, v.x, v.y
  FROM stats st
  CROSS JOIN (VALUES ('WIOSTK', 50, 50), ('WIOSTI', 50, 68), ('WISCRT2', 50, 86),
                     ('WITIME', 16, 168), ('WIPAR', 176, 168)) v(name, x, y)
  UNION ALL
  -- WI_drawPercent: % at x, the digits to its left (WI_drawNum, 11 pixels each)
  SELECT 1, 'WIPCNT', n.x, n.y FROM nums n WHERE n.kind = 'pct'
  UNION ALL
  SELECT 1, 'WINUM' || ((n.val / (10 ^ d.j)::int) % 10)::text, n.x - (d.j + 1) * 11, n.y
  FROM nums n
  CROSS JOIN LATERAL generate_series(0, length(n.val::text) - 1) d(j)
  WHERE n.kind = 'pct'
  UNION ALL
  -- WI_drawTime: :SS, MM:SS from a minute (two digits each, the colon 5
  -- pixels wide); SUCKS past 61 * 59 s
  SELECT 1, 'WINUM' || (CASE d.j WHEN 0 THEN n.val % 10 WHEN 1 THEN (n.val % 60) / 10
                                 WHEN 2 THEN (n.val / 60 % 60) % 10 ELSE (n.val / 60 % 60) / 10 END)::text,
         n.x - CASE d.j WHEN 0 THEN 11 WHEN 1 THEN 22 WHEN 2 THEN 38 ELSE 49 END, n.y
  FROM nums n CROSS JOIN generate_series(0, 3) d(j)
  WHERE n.kind = 'time' AND n.val <= 61 * 59 AND (d.j < 2 OR n.val >= 60)
  UNION ALL
  SELECT 1, 'WICOLON', n.x - 27, n.y FROM nums n WHERE n.kind = 'time' AND n.val <= 61 * 59
  UNION ALL
  SELECT 1, su.name, n.x - su.width, n.y
  FROM nums n JOIN pw su ON su.name = 'WISUCKS'
  WHERE n.kind = 'time' AND n.val > 61 * 59
  UNION ALL
  -- WI_drawShowNextLoc: a splat on each level done; on M9 once played
  SELECT 1, 'WISPLAT', l.x, l.y
  FROM nextloc nl JOIN lnode l ON nl.ep = 1
   AND (l.n <= CASE WHEN nl.lv = 9 THEN nl.nx - 2 ELSE nl.lv - 1 END OR (l.n = 8 AND nl.did_secret))
  UNION ALL
  -- the blinking arrow on the next level (WI_drawOnLnode: WIURH0, or WIURH1
  -- where WIURH0 would leave the screen)
  SELECT 2, ptr.name, l.x, l.y
  FROM nextloc nl JOIN lnode l ON nl.ep = 1 AND l.n = nl.nx - 1
  CROSS JOIN LATERAL (
    SELECT p.name FROM pw p WHERE p.name IN ('WIURH0', 'WIURH1')
    ORDER BY (l.x - p.left_offset >= 0 AND l.x - p.left_offset + p.width < 320
              AND l.y - p.top_offset >= 0 AND l.y - p.top_offset + p.height < 200) DESC, p.name
    LIMIT 1) ptr
  WHERE nl.st = 12 OR (nl.cnt & 31) < 20
  UNION ALL
  -- WI_drawEL (after the arrow, so over it): ENTERING, centred, the next
  -- level's name under it
  SELECT 3, e.name, (320 - e.width) / 2, 2 FROM nextloc nl JOIN pw e ON e.name = 'WIENTER'
  UNION ALL
  SELECT 3, ln.name, (320 - ln.width) / 2, 2 + (5 * ln.height) / 4
  FROM nextloc nl JOIN pw ln ON ln.name = 'WILV' || (nl.ep - 1)::text || (nl.nx - 1)::text
  UNION ALL
  -- the episode's end text
  SELECT 3, g.glyph, g.cx, g.cy FROM glyphs g WHERE g.glyph IS NOT NULL AND g.cx + g.w <= 320
),
-- the background, 64,000 palette indices, detoasted once
bg AS MATERIALIZED (
  SELECT COALESCE(
    (SELECT p.pixels FROM s JOIN ui_patches p ON p.name = 'WIMAP' || (s.ep - 1)::text
     WHERE s.screen = 'intermission'),
    (SELECT p.pixels FROM s JOIN ui_patches p ON p.name = 'INTERPIC' WHERE s.screen = 'intermission'),
    -- F_TextWrite: the flat (64 x 64) tiled over the screen
    (SELECT string_agg(substring(fl.b FROM (g.y % 64) * 64 + 1 FOR 64) || substring(fl.b FROM (g.y % 64) * 64 + 1 FOR 64)
                       || substring(fl.b FROM (g.y % 64) * 64 + 1 FOR 64) || substring(fl.b FROM (g.y % 64) * 64 + 1 FOR 64)
                       || substring(fl.b FROM (g.y % 64) * 64 + 1 FOR 64), ''::bytea ORDER BY g.y)
     FROM (SELECT ft.palette_indices || ''::bytea AS b
           FROM s JOIN finale_defs f ON f.episode = s.fep JOIN flat_textures ft ON ft.name = f.flat
           WHERE s.screen = 'finale' AND s.fst = 0) fl
     CROSS JOIN generate_series(0, 199) g(y)
     HAVING count(*) > 0),
    -- F_Drawer, the picture: HELP2 in the shareware game (no episode 2
    -- loaded), the episode's own otherwise
    (SELECT p.pixels FROM s JOIN finale_defs f ON f.episode = s.fep
     JOIN ui_patches p ON p.name = CASE WHEN f.episode = 1
                                         AND EXISTS (SELECT 1 FROM ui_patches h WHERE h.name = 'HELP2')
                                         AND NOT EXISTS (SELECT 1 FROM maps m WHERE m.name ~ '^E[2-4]M')
                                        THEN 'HELP2' ELSE f.patch END
     WHERE s.screen = 'finale' AND s.fst >= 1)
  ) || ''::bytea AS b
),
placed AS (
  SELECT l.z, l.name, l.x - p.left_offset AS x0, l.y - p.top_offset AS y0
  FROM layers l JOIN pw p ON p.name = l.name
),
-- the placed patches' opaque runs, clipped to the screen
clipped AS (
  SELECT r.z, r.y, GREATEST(r.x, 0) AS x0, LEAST(r.x + r.len, 320) AS x1,
         substring(r.b FROM GREATEST(0, -r.x) + 1 FOR LEAST(r.x + r.len, 320) - GREATEST(r.x, 0)) AS b
  FROM (SELECT pl.z, pl.y0 + sr.dy AS y, pl.x0 + sr.dx AS x, sr.len, sr.b
        FROM placed pl JOIN ui_screen_runs sr ON sr.name = pl.name) r
  WHERE r.y BETWEEN 0 AND 199 AND r.x < 320 AND r.x + r.len > 0
),
-- The background cut into its 200 rows once (2026-11-22): joined whole, its
-- 64,000 bytes rode along with every run and every pixel into the sorts of
-- the string_aggs below, ~20 MB, which spilled to disk at the frame threads'
-- work_mem (8 MB): 380 ms a frame with the episode map's animations (44 ms
-- at 64 MB), so the counting looked slow.
bg_rows AS MATERIALIZED (
  SELECT g.y, substring(bg.b FROM g.y * 320 + 1 FOR 320) AS r
  FROM bg CROSS JOIN generate_series(0, 199) g(y)
  WHERE bg.b IS NOT NULL
),
ordered AS (
  SELECT c.*, MAX(c.x1) OVER (PARTITION BY c.y ORDER BY c.x0, c.z
                              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_end
  FROM clipped c
),
row_kind AS (
  SELECT o.y, bool_or(o.x0 < COALESCE(o.prev_end, 0)) AS overlap, MAX(o.x1) AS last_end
  FROM ordered o GROUP BY o.y
),
-- a row whose runs do not overlap: the background between them, spliced
spliced AS (
  SELECT o.y, string_agg(substring(br.r FROM COALESCE(o.prev_end, 0) + 1
                                   FOR o.x0 - COALESCE(o.prev_end, 0)) || o.b, ''::bytea ORDER BY o.x0, o.z) AS b
  FROM ordered o
  JOIN row_kind rk ON rk.y = o.y AND NOT rk.overlap
  JOIN bg_rows br ON br.y = o.y
  GROUP BY o.y
),
-- a row where patches overlap (the arrow under ENTERING): pixel by pixel,
-- the top layer's
pixel_top AS (
  SELECT DISTINCT ON (c.y, c.x0 + g.j) c.y, c.x0 + g.j AS x, substring(c.b FROM g.j + 1 FOR 1) AS px
  FROM clipped c
  JOIN row_kind rk ON rk.y = c.y AND rk.overlap
  CROSS JOIN LATERAL generate_series(0, c.x1 - c.x0 - 1) g(j)
  ORDER BY c.y, c.x0 + g.j, c.z DESC, c.x0 DESC
),
pixel_rows AS (
  SELECT rk.y, string_agg(COALESCE(pt.px, substring(br.r FROM x.x + 1 FOR 1)),
                          ''::bytea ORDER BY x.x) AS b
  FROM row_kind rk
  JOIN bg_rows br ON br.y = rk.y
  CROSS JOIN generate_series(0, 319) x(x)
  LEFT JOIN pixel_top pt ON pt.y = rk.y AND pt.x = x.x
  WHERE rk.overlap
  GROUP BY rk.y
),
rows_out AS (
  SELECT g.y,
         COALESCE(pr.b,
                  sp.b || substring(g.r FROM rk.last_end + 1 FOR 320 - rk.last_end),
                  g.r) AS b
  FROM bg_rows g
  LEFT JOIN row_kind rk ON rk.y = g.y
  LEFT JOIN spliced sp ON sp.y = g.y
  LEFT JOIN pixel_rows pr ON pr.y = g.y
)
SELECT CASE WHEN bg.b IS NOT NULL AND octet_length(bg.b) = 64000
            THEN '\x00'::bytea || (SELECT string_agg(ro.b, ''::bytea ORDER BY ro.y) FROM rows_out ro) END AS frame_rgb
FROM bg;
