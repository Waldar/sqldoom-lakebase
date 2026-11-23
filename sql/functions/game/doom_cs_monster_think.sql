CREATE OR REPLACE FUNCTION doom.doom_cs_monster_think(p_map_id integer, p_player_thing_id integer)
 RETURNS void
 LANGUAGE plpgsql
 SET enable_nestloop TO 'off'
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  attack_range_default double precision;
  sight_range double precision;
  melee_reach double precision;
BEGIN

-- 3 constants in one scan
SELECT
       COALESCE(max(value) FILTER (WHERE name = 'DEFAULT_ATTACK_RANGE'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'SIGHT_RANGE'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'MELEE_REACH'), 0)
  INTO attack_range_default, sight_range, melee_reach
  FROM doom_constants WHERE name IN ('DEFAULT_ATTACK_RANGE', 'SIGHT_RANGE', 'MELEE_REACH');
-- activation + state/frame advancement
WITH RECURSIVE
params AS NOT MATERIALIZED (SELECT doom_cs_monster_think.p_map_id::int AS map_id, doom_cs_monster_think.p_player_thing_id::int AS player_thing_id),
player_pos AS (
  SELECT pp.px, pp.py
  FROM doom_player_pos pp JOIN params p ON pp.map_id = p.map_id
   AND pp.player_thing_id = p.player_thing_id
),
-- MF_SHADOW on the target, which for the player means the blur sphere.
shadow AS (
  SELECT sh.shadowed, sh.level_tics
  FROM doom_player_shadow sh JOIN params p ON sh.map_id = p.map_id
   AND sh.player_thing_id = p.player_thing_id
),
blocking_walls AS (
  SELECT ld.x1::double precision AS x1, ld.y1::double precision AS y1,
         ld.x2::double precision AS x2, ld.y2::double precision AS y2
  FROM linedef_geom ld
  JOIN params p ON ld.map_id = p.map_id
  LEFT JOIN sectors fr ON fr.map_id = ld.map_id AND fr.id = ld.fsec
  LEFT JOIN sectors bk ON bk.map_id = ld.map_id AND bk.id = ld.bsec
  -- Sight is blocked by one-sided walls and by live two-sided portals with no
  -- vertical opening.
  WHERE ld.left_sd_id = -1 OR ld.right_sd_id = -1
     OR fr.id IS NULL OR bk.id IS NULL
     OR LEAST(fr.ceil_height, bk.ceil_height)
          <= GREATEST(fr.floor_height, bk.floor_height)
),
monsters AS (
  SELECT ai.map_id, ai.thing_id, ai.state, ai.state_tics, ai.seq_index,
         ai.attack_cooldown, t.type, t.x::double precision AS mx,
         t.y::double precision AS my, t.angle::double precision AS facing,
         h.alive, h.health, h.max_health, cd.xdeath_frame,
         COALESCE(cd.explodes, FALSE) AS explodes,
         COALESCE(cd.attack_range, _cs.attack_range_default)::double precision AS attack_range,
         ai.movecount, ai.heard, cd.melee_mult,
         -- P_CheckSight's eye: z + height - height/4
         (CASE WHEN cd.floats THEN t.z::double precision ELSE ms.floor_height::double precision END)
           + COALESCE(cd.height, 56) * 0.75 AS eye_z
  FROM monster_ai ai
  JOIN params p ON ai.map_id = p.map_id
  JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
  JOIN thing_health h ON h.map_id = ai.map_id AND h.thing_id = ai.thing_id
  LEFT JOIN thing_combat_defs cd ON cd.thing_type = t.type
  LEFT JOIN render_things mrt ON mrt.map_id = ai.map_id AND mrt.thing_id = ai.thing_id
  LEFT JOIN sectors ms ON ms.map_id = ai.map_id AND ms.id = COALESCE(ai.sector_id, mrt.sector_id)
  WHERE h.alive OR ai.state <> 'dead'
),
-- the game's skill (Nightmare: no movecount wait before a missile, no reaction time)
skill AS (
  SELECT g.skill FROM game_tic_commands g JOIN params p ON g.map_id = p.map_id
   AND g.player_thing_id = p.player_thing_id
),
mon_target AS (
  SELECT ai.thing_id,
         COALESCE(tt.x::double precision, pp.px) AS tx,
         COALESCE(tt.y::double precision, pp.py) AS ty,
         -- the target's feet and height, for P_CheckSight's slopes: a monster
         -- target stands on its sector's floor, a player on the player's
         COALESCE(tfl.floor_height, pfl.floor_height)::double precision AS tz,
         COALESCE(tcd.height, 56)::double precision AS th
  FROM monster_ai ai
  JOIN params p ON ai.map_id = p.map_id
  CROSS JOIN player_pos pp
  LEFT JOIN (SELECT map_id, thing_id FROM thing_health WHERE alive
             UNION ALL SELECT map_id, player_thing_id FROM player_state WHERE alive) th
    ON th.map_id = ai.map_id AND th.thing_id = ai.target_thing_id
  LEFT JOIN things tt ON tt.map_id = ai.map_id AND tt.id = th.thing_id
  LEFT JOIN thing_combat_defs tcd ON tcd.thing_type = tt.type
  LEFT JOIN monster_ai tai ON tai.map_id = ai.map_id AND tai.thing_id = tt.id
  LEFT JOIN render_things trt ON trt.map_id = ai.map_id AND trt.thing_id = tt.id
  LEFT JOIN sectors tfl ON tfl.map_id = ai.map_id AND tfl.id = COALESCE(tai.sector_id, trt.sector_id)
  LEFT JOIN player_state ps ON ps.map_id = ai.map_id
   AND ps.player_thing_id = COALESCE(th.thing_id, p.player_thing_id)
  LEFT JOIN sectors pfl ON pfl.map_id = ai.map_id AND pfl.id = ps.sector_id
),
near_monsters AS (
  SELECT m.thing_id, m.mx, m.my, m.facing, mt.tx, mt.ty, m.eye_z, mt.tz, mt.th,
         sqrt(power(m.mx - mt.tx, 2) + power(m.my - mt.ty, 2)) AS total
  FROM monsters m
  JOIN mon_target mt ON mt.thing_id = m.thing_id
  WHERE power(m.mx - mt.tx, 2) + power(m.my - mt.ty, 2) <= _cs.sight_range * _cs.sight_range
),
near_los_walls AS MATERIALIZED (
  -- P_CheckSight (2026-11-24): a wall with no opening blocks the sight line;
  -- every other two-sided line it crosses narrows the slopes from the eye to
  -- the target's top and feet by its opening (P_CrossSubsector), so a
  -- window or a ledge the line passes too high or too low blocks it too.
  -- Until then only the walls with no opening were tested: monsters saw and
  -- shot through any opening at all.
  SELECT nm.thing_id,
         BOOL_OR(b.blocking AND xs.crosses) AS blocked,
         MIN((b.opentop - nm.eye_z) / NULLIF(xs.f * nm.total, 0))
           FILTER (WHERE xs.crosses AND NOT b.blocking AND b.ceil_differs) AS top_slope,
         MAX((b.openbottom - nm.eye_z) / NULLIF(xs.f * nm.total, 0))
           FILTER (WHERE xs.crosses AND NOT b.blocking AND b.floor_differs) AS bottom_slope
  FROM near_monsters nm
  CROSS JOIN params p
  -- Spatial: GiST probe for the walls whose box overlaps the sight line's box,
  -- then the live blocking rule on those walls only.
  JOIN linedef_geom ld
    ON ld.map_id = p.map_id
   AND box(point(ld.x1::double precision, ld.y1::double precision),
           point(ld.x2::double precision, ld.y2::double precision))
       && box(point(nm.mx, nm.my), point(nm.tx, nm.ty))
  LEFT JOIN sectors fr ON fr.map_id = ld.map_id AND fr.id = ld.fsec
  LEFT JOIN sectors bk ON bk.map_id = ld.map_id AND bk.id = ld.bsec
  CROSS JOIN LATERAL (
    SELECT ld.x1::double precision AS x1, ld.y1::double precision AS y1,
           ld.x2::double precision AS x2, ld.y2::double precision AS y2,
           (ld.left_sd_id = -1 OR ld.right_sd_id = -1
            OR fr.id IS NULL OR bk.id IS NULL
            OR LEAST(fr.ceil_height, bk.ceil_height)
                 <= GREATEST(fr.floor_height, bk.floor_height)) AS blocking,
           LEAST(fr.ceil_height, bk.ceil_height)::double precision AS opentop,
           GREATEST(fr.floor_height, bk.floor_height)::double precision AS openbottom,
           fr.ceil_height IS DISTINCT FROM bk.ceil_height AS ceil_differs,
           fr.floor_height IS DISTINCT FROM bk.floor_height AS floor_differs
  ) b
  CROSS JOIN LATERAL (
    SELECT
      (nm.mx - b.x1) * (b.y2 - b.y1) - (nm.my - b.y1) * (b.x2 - b.x1) AS d1,
      (nm.tx - b.x1) * (b.y2 - b.y1) - (nm.ty - b.y1) * (b.x2 - b.x1) AS d2,
      (b.x1 - nm.mx) * (nm.ty - nm.my) - (b.y1 - nm.my) * (nm.tx - nm.mx) AS d3,
      (b.x2 - nm.mx) * (nm.ty - nm.my) - (b.y2 - nm.my) * (nm.tx - nm.mx) AS d4
  ) sides
  CROSS JOIN LATERAL (
    SELECT (sides.d1 * sides.d2 < 0) AND (sides.d3 * sides.d4 < 0) AS crosses,
           -- how far along the sight line it crosses, 0 at the eye, 1 at the target
           sides.d1 / NULLIF(sides.d1 - sides.d2, 0) AS f
  ) xs
  GROUP BY nm.thing_id
),
near_los AS MATERIALIZED (
  SELECT nm.thing_id,
    NOT COALESCE(w.blocked, FALSE)
      -- the target's slopes, narrowed by every opening on the way
      AND LEAST((nm.tz + nm.th - nm.eye_z) / NULLIF(nm.total, 0), COALESCE(w.top_slope, 'Infinity'))
        > GREATEST((nm.tz - nm.eye_z) / NULLIF(nm.total, 0), COALESCE(w.bottom_slope, '-Infinity'))
      AS visible,
    (COS(RADIANS(nm.facing)) * (nm.tx - nm.mx)
     + SIN(RADIANS(nm.facing)) * (nm.ty - nm.my)) > 0 AS in_view_cone
  FROM near_monsters nm
  LEFT JOIN near_los_walls w ON w.thing_id = nm.thing_id
),
los AS (
  SELECT m.thing_id,
    COALESCE(nl.visible, FALSE) AS visible,
    COALESCE(nl.in_view_cone, FALSE) AS in_view_cone,
    sqrt(power(m.mx - mt.tx, 2) + power(m.my - mt.ty, 2)) AS dist
  FROM monsters m
  JOIN mon_target mt ON mt.thing_id = m.thing_id
  LEFT JOIN near_los nl ON nl.thing_id = m.thing_id
),
max_seq AS (
  SELECT thing_type,
         MAX(seq_index) FILTER (WHERE state = 'see') AS see_max,
         MAX(seq_index) FILTER (WHERE state = 'missile') AS missile_max,
         MAX(seq_index) FILTER (WHERE state = 'pain') AS pain_max,
         MAX(seq_index) FILTER (WHERE state = 'die') AS die_max,
         MAX(seq_index) FILTER (WHERE state = 'xdeath') AS xdeath_max
  FROM thing_ai_frames GROUP BY thing_type
),
decision AS (
  SELECT
    m.map_id, m.thing_id, m.state, m.state_tics, m.seq_index,
    m.attack_cooldown, m.type, m.alive, m.health, m.max_health,
    m.xdeath_frame, m.explodes, l.visible, l.in_view_cone, l.dist,
    m.attack_range,
    ms.see_max, ms.missile_max, ms.pain_max, ms.die_max, ms.xdeath_max,
    m.heard,
    -- A_Chase's attack (2026-11-24), checked when a see frame ends; until then
    -- a monster shot whenever it saw its target within attack_range, 30 tics
    -- after its last shot. attack_cooldown > 0: MF_JUSTATTACKED (the chase
    -- after an attack only moves) or the reaction time after waking; -1:
    -- MF_JUSTHIT, hurt into pain, which fires back at once.
    l.visible AND m.attack_cooldown <= 0 AND (
      -- P_CheckMeleeRange, no dice
      (m.melee_mult IS NOT NULL AND l.dist <= _cs.melee_reach)
      -- P_CheckMissileRange: not while the chase direction still has steps
      -- to run (except on Nightmare), then a die against the distance:
      -- dist - 64, - 128 more without a melee attack, halved for the lost
      -- soul, the cyberdemon and the spider, at most 200 (160 for the
      -- cyberdemon), and the shot is off when P_Random() < that
      OR (m.attack_range > _cs.melee_reach AND l.dist <= m.attack_range
          AND (sk.skill = 4 OR m.movecount = 0)
          AND (m.attack_cooldown = -1
               OR doom_prandom(m.thing_id, sh.level_tics, 61)
                  >= LEAST(CASE WHEN m.type = 16 THEN 160 ELSE 200 END,
                           GREATEST(0, (l.dist - 64 - CASE WHEN m.melee_mult IS NULL THEN 128 ELSE 0 END)
                                       / CASE WHEN m.type IN (3006, 16, 7) THEN 2 ELSE 1 END))))
    ) AS attack_ok
  FROM monsters m
  JOIN los l ON l.thing_id = m.thing_id
  LEFT JOIN max_seq ms ON ms.thing_type = m.type
  LEFT JOIN skill sk ON TRUE
  LEFT JOIN shadow sh ON TRUE
),
transitions AS (
  SELECT d.*,
    d.state_tics <= 1
      OR (NOT d.alive AND d.state NOT IN ('die', 'dead', 'xdeath'))
      AS advances,
    CASE
      -- P_KillMobj: `health < -spawnhealth && xdeathstate` takes the extreme
      -- death rather than the ordinary one
      WHEN NOT d.alive AND d.state NOT IN ('die', 'dead', 'xdeath') THEN
        CASE WHEN d.health < -d.max_health AND d.xdeath_frame IS NOT NULL
             THEN 'xdeath'::actor_state ELSE 'die'::actor_state END
      WHEN d.state = 'die' THEN
        CASE WHEN d.state_tics > 1 THEN 'die'::actor_state
             WHEN d.seq_index >= d.die_max THEN 'dead'::actor_state
             ELSE 'die'::actor_state END
      WHEN d.state = 'xdeath' THEN
        CASE WHEN d.state_tics > 1 THEN 'xdeath'::actor_state
             WHEN d.seq_index >= d.xdeath_max THEN 'dead'::actor_state
             ELSE 'xdeath'::actor_state END
      -- Barrels use this same compact actor state table only for their death
      -- animation. While alive they never wake, chase, or attack.
      WHEN d.explodes THEN 'stand'::actor_state
      -- A_Look: seen in the 180-degree cone, or in any direction once a deaf
      -- monster has heard the player (heard, doom_cs_monster_noise)
      WHEN d.state = 'stand' THEN
        CASE WHEN d.visible AND (d.in_view_cone OR d.heard) AND d.dist <= _cs.sight_range
              THEN 'see'::actor_state ELSE 'stand'::actor_state END
      WHEN d.state_tics > 1 THEN d.state
      WHEN d.state = 'see' THEN
        CASE WHEN d.attack_ok
             THEN 'missile'::actor_state ELSE 'see'::actor_state END
      WHEN d.state = 'missile' THEN
        CASE WHEN d.seq_index >= d.missile_max THEN 'see'::actor_state ELSE 'missile'::actor_state END
      WHEN d.state = 'pain' THEN
        CASE WHEN d.seq_index >= d.pain_max THEN 'see'::actor_state ELSE 'pain'::actor_state END
      ELSE d.state
    END AS next_state,
    CASE
      WHEN NOT d.alive AND d.state NOT IN ('die', 'dead', 'xdeath') THEN 0
      WHEN d.state = 'die' THEN
        CASE WHEN d.state_tics > 1 THEN d.seq_index
             WHEN d.seq_index >= d.die_max THEN 0
             ELSE d.seq_index + 1 END
      WHEN d.state = 'xdeath' THEN
        CASE WHEN d.state_tics > 1 THEN d.seq_index
             WHEN d.seq_index >= d.xdeath_max THEN 0
             ELSE d.seq_index + 1 END
      WHEN d.explodes THEN 0
      WHEN d.state = 'stand' THEN 0
      WHEN d.state_tics > 1 THEN d.seq_index
      WHEN d.state = 'see' THEN
        CASE WHEN d.attack_ok
             THEN 0
             WHEN d.seq_index >= d.see_max THEN 0
             ELSE d.seq_index + 1 END
      WHEN d.state = 'missile' THEN
        CASE WHEN d.seq_index >= d.missile_max THEN 0 ELSE d.seq_index + 1 END
      WHEN d.state = 'pain' THEN
        CASE WHEN d.seq_index >= d.pain_max THEN 0 ELSE d.seq_index + 1 END
      ELSE d.seq_index
    END AS next_seq
  FROM decision d
),
next_values AS (
  SELECT t.map_id, t.thing_id, t.state AS old_state, t.next_state,
         t.next_seq, t.type, t.advances,
         CASE
           WHEN NOT t.advances THEN t.state_tics - 1
           WHEN t.next_state = 'stand' THEN -1
           -- G_InitNew's fast-monster loop halves the tics of every state
           -- from S_SARG_RUN1 to S_SARG_PAIN2 on Nightmare
           WHEN cd.fast_on_nightmare
                AND t.next_state IN ('see','missile','pain')
                AND (SELECT g.skill FROM game_tic_commands g
                     WHERE g.map_id=doom_cs_monster_think.p_map_id::int
                       AND g.player_thing_id=doom_cs_monster_think.p_player_thing_id::int)=4
             THEN GREATEST(1, COALESCE(f.tics, -1) >> 1)
           ELSE COALESCE(f.tics, -1)
         END AS next_tics,
         CASE -- MF_JUSTATTACKED: the next chase only moves (until the see frame it lands on ends)
              WHEN t.state = 'missile' AND t.next_state = 'see' THEN COALESCE(f.tics, 1)
              -- reactiontime 8: eight chases after waking before the first shot (not on Nightmare)
              WHEN t.state = 'stand' AND t.next_state = 'see'
                THEN CASE WHEN (SELECT s.skill FROM skill s) = 4 THEN 0
                          ELSE 8 * COALESCE(f.tics, 3) / COALESCE(mc.calls_per_frame, 2) END
              -- MF_JUSTHIT: kept until the see frame's end that checks it
              WHEN t.state = 'pain' AND t.next_state = 'see' THEN -1
              WHEN t.attack_cooldown = -1 AND NOT (t.advances AND t.state = 'see') THEN -1
              ELSE GREATEST(0, t.attack_cooldown - 1) END AS next_cooldown,
         COALESCE(f.is_attack_frame, FALSE) AS lands_on_attack_frame
  FROM transitions t
  JOIN thing_combat_defs cd ON cd.thing_type = t.type
  LEFT JOIN monster_chase_defs mc ON mc.thing_type = t.type
  LEFT JOIN thing_ai_frames f
    ON f.thing_type = t.type AND f.state = t.next_state
   AND f.seq_index = t.next_seq
),
-- A_FaceTarget (2026-11-21; owner: monsters fire without looking at me).
-- Every attack frame of Doom's monsters turns the monster to its target,
-- first (S_POSS_ATK1 and the like) and again as it fires (A_PosAttack,
-- A_TroopAttack, ... start with A_FaceTarget). Here a monster's angle only
-- changed when it stepped (doom_cs_monster_move), so one that stopped to
-- shoot kept its last step's facing, and its sprite showed a side or its
-- back. A frame of the attack begun this tic: the angle to the target, with
-- MF_SHADOW's `(P_Random()-P_Random())<<21` when the player has the blur
-- sphere -- the same numbers as the shot's error (doom_cs_monster_attack's
-- shadow_err, seeds 15 and 16 at this tic), so it faces where it fires.
faced AS (
  UPDATE things t
  SET angle = mod((degrees(atan2(mt.ty - m.my, mt.tx - m.mx))
                   + CASE WHEN COALESCE(sh.shadowed, FALSE)
                          THEN (doom_prandom(n.thing_id, sh.level_tics, 15)
                                - doom_prandom(n.thing_id, sh.level_tics, 16)) * 360.0
                               / NULLIF((SELECT c.value FROM doom_constants c WHERE c.name = 'SHADOW_MISS_UNITS'), 0)
                          ELSE 0.0 END
                   + 720.0)::numeric, 360)::real
  FROM next_values n
  JOIN monsters m ON m.thing_id = n.thing_id
  JOIN mon_target mt ON mt.thing_id = n.thing_id
  LEFT JOIN shadow sh ON TRUE
  WHERE n.advances AND n.next_state = 'missile'
    AND t.map_id = n.map_id AND t.id = n.thing_id
    AND (mt.tx <> m.mx OR mt.ty <> m.my)
  RETURNING t.id
)
UPDATE monster_ai ai
SET state = n.next_state, state_tics = n.next_tics,
    seq_index = n.next_seq, attack_cooldown = n.next_cooldown,
    fired_this_tick = n.advances AND n.lands_on_attack_frame
FROM next_values n
WHERE ai.map_id = n.map_id AND ai.thing_id = n.thing_id
  AND (ai.state <> n.next_state
    OR ai.state_tics <> n.next_tics
    OR ai.seq_index <> n.next_seq
    OR ai.attack_cooldown <> n.next_cooldown
    OR ai.fired_this_tick <> (n.advances AND n.lands_on_attack_frame));
RETURN;
END _cs;
$function$;
