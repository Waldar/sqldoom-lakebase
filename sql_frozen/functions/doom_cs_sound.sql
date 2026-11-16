CREATE OR REPLACE FUNCTION doom.doom_cs_sound(p_map_id integer, p_player_thing_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  active_sound_odds double precision;
  sound_trim_age double precision;
  sound_trim_interval double precision;
  world_cues boolean;
  level_tic integer;
  _r1 record;
  _r2 record;
BEGIN

-- 3 constants in one scan (was 3 doom_const() calls)
SELECT
       COALESCE(max(value) FILTER (WHERE name = 'ACTIVE_SOUND_ODDS'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'SOUND_TRIM_AGE_TICS'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'SOUND_TRIM_INTERVAL_TICS'), 0)
  INTO active_sound_odds, sound_trim_age, sound_trim_interval
  FROM doom_constants WHERE name IN ('ACTIVE_SOUND_ODDS', 'SOUND_TRIM_AGE_TICS', 'SOUND_TRIM_INTERVAL_TICS');
-- World cues (monsters, impacts) are the same for every listener: emit them
-- in the first call of the tic that has a player, not once per player slot.
-- The flag is transaction-local (one tic = one transaction).
world_cues := COALESCE(current_setting('doom.sound_world', true), '') = '';
-- Emit one tic's sound events
WITH
pickup AS (
  SELECT map_id,player_thing_id,COUNT(*)>0 AS changed
  FROM pickup_touches GROUP BY map_id,player_thing_id
),
weapon_grant AS (
  SELECT map_id,player_thing_id,COUNT(*)>0 AS granted
  FROM pickup_grants GROUP BY map_id,player_thing_id
),
input AS (
  SELECT g.map_id,g.player_thing_id,ps.level_tics AS level_tic,
         COALESCE(p.changed,FALSE) AS pickup_changed,
         COALESCE(gr.granted,FALSE) AS weapon_granted,g.use_requested
  FROM game_tic_commands g
  JOIN player_state ps ON ps.map_id=g.map_id
    AND ps.player_thing_id=g.player_thing_id
  LEFT JOIN pickup p ON p.map_id=g.map_id AND p.player_thing_id=g.player_thing_id
  LEFT JOIN weapon_grant gr ON gr.map_id=g.map_id
    AND gr.player_thing_id=g.player_thing_id
  WHERE g.map_id=doom_cs_sound.p_map_id::int AND g.player_thing_id=doom_cs_sound.p_player_thing_id::int
),
player_pos AS (
  SELECT i.*,t.x::real AS px,t.y::real AS py
  FROM input i JOIN things t ON t.map_id=i.map_id AND t.id=i.player_thing_id
),
world_pos AS (
  SELECT p.* FROM player_pos p WHERE _cs.world_cues
),
sound_pick AS (
  SELECT d.thing_type, d.cue, d.variant, d.sound_name,
         COUNT(*) OVER (PARTITION BY d.thing_type, d.cue) AS n
  FROM thing_sound_defs d
),
events AS (
  SELECT p.map_id,'player-fire:'||p.player_thing_id::text||':'||pw.shot_serial::text AS event_key,
         p.level_tic,
         CASE pw.current_weapon
           WHEN 1 THEN 'DSPUNCH' WHEN 2 THEN 'DSPISTOL'
           WHEN 3 THEN 'DSSHOTGN' WHEN 4 THEN 'DSPISTOL'
           WHEN 5 THEN 'DSRLAUNC' WHEN 6 THEN 'DSPLASMA'
           WHEN 7 THEN 'DSBFG' WHEN 8 THEN NULL
         END AS sound_name,p.player_thing_id AS source_thing_id,
         p.px AS source_x,p.py AS source_y
  FROM player_pos p JOIN player_weapons pw
    ON pw.map_id=p.map_id AND pw.player_thing_id=p.player_thing_id
  WHERE pw.fired_this_tick

  UNION ALL
  SELECT p.map_id,'pickup:'||p.player_thing_id::text||':'||p.level_tic::text,p.level_tic,
         CASE WHEN p.weapon_granted THEN 'DSWPNUP' ELSE 'DSITEMUP' END,
         p.player_thing_id,p.px,p.py
  FROM player_pos p WHERE p.pickup_changed

  UNION ALL
  SELECT p.map_id,'use:'||p.player_thing_id::text||':'||p.level_tic::text,p.level_tic,
         CASE
           WHEN COALESCE(r.locked,FALSE) THEN 'DSOOF'
           WHEN COALESCE(r.eligible,FALSE) AND r.special IN
                (1,26,27,28,31,32,33,34,117,118) THEN 'DSDOROPN'
           WHEN COALESCE(r.eligible,FALSE) THEN 'DSSWTCHN'
           ELSE 'DSNOWAY'
         END,
         p.player_thing_id,p.px,p.py
  FROM player_pos p
  LEFT JOIN line_use_results r ON r.map_id=p.map_id
    AND r.player_thing_id=p.player_thing_id
  WHERE p.use_requested

  UNION ALL
  SELECT p.map_id,
         'monster-fire:'||ai.thing_id::text||':'||p.level_tic::text,
         p.level_tic,
         CASE
           WHEN d.attack_sound IS NOT NULL THEN d.attack_sound
           WHEN d.missile_type IS NOT NULL
                AND NOT (d.melee_mult IS NOT NULL
                         AND sqrt(power(t.x-p.px,2)+power(t.y-p.py,2))<=64.0)
             THEN 'DSFIRSHT'
           ELSE 'DSCLAW'
         END,
         ai.thing_id,t.x::real,t.y::real
  -- Firing monsters first (a few), not every Thing of the map.
  FROM world_pos p JOIN (SELECT ai0.* FROM monster_ai ai0
                         WHERE ai0.map_id=doom_cs_sound.p_map_id::int AND ai0.fired_this_tick
                         OFFSET 0) ai ON ai.map_id=p.map_id
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_combat_defs d ON d.thing_type=t.type

  UNION ALL
  SELECT p.map_id,'impact:'||i.projectile_id::text,p.level_tic,
         CASE i.projectile_type WHEN 'rocket' THEN 'DSRXPLOD'
              ELSE 'DSFIRXPL' END,
         i.owner_thing_id,i.x::real,i.y::real
  FROM world_pos p JOIN projectile_impacts i ON i.map_id=p.map_id

  UNION ALL
  SELECT p.map_id,'mon-sight:'||ai.thing_id::text,p.level_tic,sp.sound_name,
         ai.thing_id,t.x::real,t.y::real
  -- Only monsters whose sight cue is not out yet: the same key test as the
  -- final NOT EXISTS, before the sound pick, not after.
  FROM world_pos p
  JOIN (SELECT ai0.* FROM monster_ai ai0
        WHERE ai0.map_id=doom_cs_sound.p_map_id::int AND ai0.state <> 'stand'
          AND NOT EXISTS (SELECT 1 FROM sound_events s0 WHERE s0.map_id=ai0.map_id
                          AND s0.event_key='mon-sight:'||ai0.thing_id::text)
        OFFSET 0) ai ON ai.map_id=p.map_id
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_health h ON h.map_id=ai.map_id AND h.thing_id=ai.thing_id
   AND h.alive
  JOIN sound_pick sp ON sp.thing_type=t.type AND sp.cue='sight'
   AND sp.variant = doom_prandom(ai.thing_id, 0, 60) % sp.n

  UNION ALL
  SELECT p.map_id,'mon-death:'||ai.thing_id::text,p.level_tic,sp.sound_name,
         ai.thing_id,t.x::real,t.y::real
  -- Only monsters whose death cue is not out yet (same key test as below).
  FROM world_pos p
  JOIN (SELECT ai0.* FROM monster_ai ai0
        JOIN thing_health h0 ON h0.map_id=ai0.map_id AND h0.thing_id=ai0.thing_id AND NOT h0.alive
        WHERE ai0.map_id=doom_cs_sound.p_map_id::int
          AND NOT EXISTS (SELECT 1 FROM sound_events s0 WHERE s0.map_id=ai0.map_id
                          AND s0.event_key='mon-death:'||ai0.thing_id::text)
        OFFSET 0) ai ON ai.map_id=p.map_id
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_health h ON h.map_id=ai.map_id AND h.thing_id=ai.thing_id
   AND NOT h.alive
  -- A_XScream: a gibbed actor slops instead of crying out.
  JOIN thing_health hh ON hh.map_id=ai.map_id AND hh.thing_id=ai.thing_id
  JOIN thing_combat_defs cdx ON cdx.thing_type=t.type
  JOIN sound_pick sp ON sp.thing_type=t.type
   AND sp.cue = CASE WHEN hh.health < -hh.max_health
                      AND cdx.xdeath_frame IS NOT NULL
                     THEN 'xdeath'::sound_cue ELSE 'death'::sound_cue END
   AND sp.variant = doom_prandom(ai.thing_id, 0, 60) % sp.n

  UNION ALL
  -- Pain
  SELECT p.map_id,
         'mon-pain:'||ai.thing_id::text||':'||p.level_tic::text,p.level_tic,
         sp.sound_name,ai.thing_id,t.x::real,t.y::real
  FROM world_pos p
  JOIN monster_ai ai ON ai.map_id=p.map_id AND ai.state='pain'
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_ai_frames f ON f.thing_type=t.type AND f.state='pain'
   AND f.seq_index=ai.seq_index AND ai.state_tics=f.tics
  JOIN sound_pick sp ON sp.thing_type=t.type AND sp.cue='pain'
   AND sp.variant = doom_prandom(ai.thing_id, 0, 60) % sp.n
  UNION ALL
  -- Chase
  SELECT p.map_id,
         'mon-act:'||ai.thing_id::text||':'||p.level_tic::text,p.level_tic,
         sp.sound_name,ai.thing_id,t.x::real,t.y::real
  -- The 1-in-ACTIVE_SOUND_ODDS draw first, per chaser, then the rest.
  FROM world_pos p
  CROSS JOIN LATERAL (SELECT ai0.* FROM monster_ai ai0
        WHERE ai0.map_id=p.map_id AND ai0.state='see'
          AND (doom_prandom(ai0.thing_id, p.level_tic, 61) * 256
               + doom_prandom(ai0.thing_id, p.level_tic, 62)) % _cs.active_sound_odds = 0
        OFFSET 0) ai
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_health h ON h.map_id=ai.map_id AND h.thing_id=ai.thing_id
   AND h.alive
  JOIN sound_pick sp ON sp.thing_type=t.type AND sp.cue='active'
   AND sp.variant = doom_prandom(ai.thing_id, 0, 60) % sp.n
  UNION ALL
  -- Player pain
  SELECT p.map_id,
         'plr-pain:'||p.player_thing_id::text||':'||(p.level_tic - (12 - ps.pain_face_tics))::text,
         p.level_tic,sp.sound_name,p.player_thing_id,p.px,p.py
  FROM player_pos p
  JOIN player_state ps ON ps.map_id=p.map_id
   AND ps.player_thing_id=p.player_thing_id
  JOIN sound_pick sp ON sp.thing_type=1 AND sp.cue='pain' AND sp.variant=0
  WHERE ps.alive AND ps.pain_face_tics > 0

  UNION ALL
  -- Player death
  SELECT p.map_id,'plr-death:'||p.player_thing_id::text,p.level_tic,sp.sound_name,
         p.player_thing_id,p.px,p.py
  FROM player_pos p
  JOIN player_state ps ON ps.map_id=p.map_id
   AND ps.player_thing_id=p.player_thing_id
  JOIN sound_pick sp ON sp.thing_type=1 AND sp.cue='death' AND sp.variant=0
  WHERE NOT ps.alive
)
INSERT INTO sound_events
  (map_id,event_key,level_tic,sound_name,source_thing_id,source_x,source_y)
SELECT map_id,event_key,level_tic,sound_name,source_thing_id,source_x,source_y
FROM events e WHERE sound_name IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM sound_events s WHERE s.map_id = e.map_id AND s.event_key = e.event_key)
ON CONFLICT (map_id,event_key) DO NOTHING;
IF _cs.world_cues THEN
  FOR _r1 IN SELECT set_config('doom.sound_world', '1', true) AS x
  FROM game_tic_commands g
  JOIN player_state ps ON ps.map_id = g.map_id AND ps.player_thing_id = g.player_thing_id
  JOIN things t ON t.map_id = g.map_id AND t.id = g.player_thing_id
  WHERE g.map_id = doom_cs_sound.p_map_id::int AND g.player_thing_id = doom_cs_sound.p_player_thing_id::int
LOOP world_cues := false; END LOOP;
END IF;

-- doom_cs_projectiles has consumed monster firing flags before this runs.
-- Clear them here so a held attack frame cannot emit the same sound on more
-- than one physics tic before doom_cs_monsters advances again.
UPDATE monster_ai SET fired_this_tick=FALSE
WHERE map_id=doom_cs_sound.p_map_id AND fired_this_tick;

level_tic := -1;
FOR _r2 IN SELECT ps.level_tics AS t FROM player_state ps
WHERE ps.map_id = doom_cs_sound.p_map_id AND ps.player_thing_id = doom_cs_sound.p_player_thing_id
LOOP level_tic := _r2.t; END LOOP;
IF _cs.level_tic >= 0 AND _cs.level_tic % _cs.sound_trim_interval = 0 THEN
  DELETE FROM sound_events e
  WHERE e.map_id = doom_cs_sound.p_map_id
    AND e.level_tic < (SELECT COALESCE(MAX(ps.level_tics), 0) - _cs.sound_trim_age
                       FROM player_state ps
                       JOIN mp_players mp ON mp.map_id = ps.map_id
                        AND mp.player_thing_id = ps.player_thing_id
                       WHERE mp.map_id = doom_cs_sound.p_map_id)
    AND e.event_key NOT LIKE 'mon-sight:%'
    AND e.event_key NOT LIKE 'mon-death:%'
    AND e.event_key NOT LIKE 'plr-death:%';
END IF;
RETURN;
END _cs;
$function$;
