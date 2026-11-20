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
-- P_TouchSpecialThing: sfx_getpow for the power-ups and the soulsphere
-- (invulnerability 2022, berserk 2023, invisibility 2024, radiation suit 2025,
-- computer map 2026, light amplification 2045, soulsphere 2013), 2026-11-20.
power_grant AS (
  SELECT pt.map_id,pt.player_thing_id,COUNT(*)>0 AS power
  FROM pickup_touches pt JOIN things it ON it.map_id=pt.map_id AND it.id=pt.thing_id
  WHERE it.type IN (2013,2022,2023,2024,2025,2026,2045)
  GROUP BY pt.map_id,pt.player_thing_id
),
input AS (
  SELECT g.map_id,g.player_thing_id,ps.level_tics AS level_tic,
         COALESCE(p.changed,FALSE) AS pickup_changed,
         COALESCE(gr.granted,FALSE) AS weapon_granted,COALESCE(pg.power,FALSE) AS power_granted,
         g.use_requested
  FROM game_tic_commands g
  JOIN player_state ps ON ps.map_id=g.map_id
    AND ps.player_thing_id=g.player_thing_id
  LEFT JOIN pickup p ON p.map_id=g.map_id AND p.player_thing_id=g.player_thing_id
  LEFT JOIN weapon_grant gr ON gr.map_id=g.map_id
    AND gr.player_thing_id=g.player_thing_id
  LEFT JOIN power_grant pg ON pg.map_id=g.map_id
    AND pg.player_thing_id=g.player_thing_id
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
         -- the fist and the chainsaw: their sounds come from what they hit
         -- (doom_cs_hitscan_apply) and the chainsaw's loop (api_sound_loops);
         -- the BFG's as it charges (doom_cs_weapon_state), not with the ball
         CASE pw.current_weapon
           WHEN 1 THEN NULL WHEN 2 THEN 'DSPISTOL'
           WHEN 3 THEN 'DSSHOTGN' WHEN 4 THEN 'DSPISTOL'
           WHEN 5 THEN 'DSRLAUNC' WHEN 6 THEN 'DSPLASMA'
           WHEN 7 THEN NULL WHEN 8 THEN NULL
         END AS sound_name,p.player_thing_id AS source_thing_id,
         p.px AS source_x,p.py AS source_y
  FROM player_pos p JOIN player_weapons pw
    ON pw.map_id=p.map_id AND pw.player_thing_id=p.player_thing_id
  WHERE pw.fired_this_tick

  UNION ALL
  SELECT p.map_id,'pickup:'||p.player_thing_id::text||':'||p.level_tic::text,p.level_tic,
         CASE WHEN p.weapon_granted THEN 'DSWPNUP' WHEN p.power_granted THEN 'DSGETPOW' ELSE 'DSITEMUP' END,
         p.player_thing_id,p.px,p.py
  FROM player_pos p WHERE p.pickup_changed

  UNION ALL
  SELECT p.map_id,'use:'||p.player_thing_id::text||':'||p.level_tic::text,p.level_tic,
         -- P_UseLines (2026-11-20): a locked door oofs; a manual door's own
         -- sound comes from its mover (doom_cs_doors); a switch clicks
         -- (sfx_swtchx for an exit) when it has a switch texture to flip, as
         -- P_ChangeSwitchTexture: line_buttons holds it (a lift worked from
         -- its plain wall, E1M2 line 178, clicked until then); a plain wall
         -- grunts (sfx_noway), as does
         -- a used-up one-shot switch (its special is cleared in Doom); a line
         -- with another special, its back side, or nothing in reach: silent.
         CASE
           WHEN COALESCE(r.locked,FALSE) THEN 'DSOOF'
           WHEN COALESCE(r.eligible,FALSE) AND d.door_target='back' THEN NULL
           WHEN COALESCE(r.eligible,FALSE) AND NOT EXISTS (SELECT 1 FROM line_buttons lb
                WHERE lb.map_id=r.map_id AND lb.line_id=r.line_id) THEN NULL
           WHEN COALESCE(r.eligible,FALSE) AND COALESCE(d.is_exit,FALSE) THEN 'DSSWTCHX'
           WHEN COALESCE(r.eligible,FALSE) THEN 'DSSWTCHN'
           WHEN r.line_id IS NOT NULL AND r.special=0 THEN 'DSNOWAY'
           WHEN r.line_id IS NOT NULL AND COALESCE(d.use_activated AND d.use_once,FALSE) THEN 'DSNOWAY'
         END,
         p.player_thing_id,p.px,p.py
  FROM player_pos p
  LEFT JOIN line_use_results r ON r.map_id=p.map_id
    AND r.player_thing_id=p.player_thing_id
  LEFT JOIN line_special_defs d ON d.special=r.special AND r.special<>0
  WHERE p.use_requested

  UNION ALL
  SELECT p.map_id,
         'monster-fire:'||ai.thing_id::text||':'||p.level_tic::text,
         p.level_tic,
         -- A_Chase's attacksound (2026-11-20): the demon and the spectre
         -- bite with sfx_sgtatk; the cacodemon's bite (A_HeadAttack) and the
         -- lost soul's charge (sfx_sklatk, not in the shareware WAD) are silent.
         CASE
           WHEN d.attack_sound IS NOT NULL THEN d.attack_sound
           WHEN t.type IN (3002,58) THEN 'DSSGTATK'
           WHEN t.type=3006 THEN NULL
           WHEN t.type=3005 AND sqrt(power(t.x-p.px,2)+power(t.y-p.py,2))<=64.0 THEN NULL
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
         -- info.c deathsound: MT_ROCKET sfx_barexp, MT_BFG sfx_rxplod, the
         -- plasma and the monsters' fireballs sfx_firxpl. (Until 2026-11-19
         -- the rocket had the BFG's sound and the BFG the fireballs'.)
         CASE i.projectile_type WHEN 'rocket' THEN 'DSBAREXP'
                                WHEN 'bfg' THEN 'DSRXPLOD'
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
  -- Player death: A_PlayerScream's sfx_pldeth (Doom 1 has no sfx_pdiehi), or
  -- A_XScream's sfx_slop when the killing blow gibbed it (death_health, the
  -- unclamped health, below -100: migration 0003), 2026-11-20
  SELECT p.map_id,'plr-death:'||p.player_thing_id::text,p.level_tic,
         CASE WHEN ps.death_health < -100 THEN 'DSSLOP' ELSE sp.sound_name END,
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
