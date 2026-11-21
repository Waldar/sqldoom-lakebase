CREATE OR REPLACE FUNCTION doom.doom_cs_face(p_map_id integer, p_player_thing_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  r record;
  pain integer;
  pri integer;
  cnt integer;
  patch text;
  since integer;
  ow integer;
  d double precision;
  until_tic integer;
BEGIN

-- The status bar face, Doom's ST_updateFaceWidget (st_stuff.c), once a tic
-- after the world has moved (ST_Ticker runs after P_Ticker). 2026-11-20; it
-- was dead / ouch on any hit / straight by health. A face index is the pain
-- level (ST_calcPainOffset) times 8 plus: 0-2 straight (STFST), 3 turned
-- right (STFTR), 4 left (STFTL), 5 ouch, 6 evil grin, 7 rampage (STFKILL);
-- god and dead are faces of their own. In priority order:
--   dead (9); a new weapon picked up: evil grin 2 s (8); hurt by an
--   attacker: turned towards it, or the rampage face head-on, 1 s (7); hurt
--   by the world (nukage, a crusher): the rampage face (6); fire held 2 s:
--   the rampage face (5); god mode or invulnerability (4); else looking
--   around, a new look every half second (0).
-- The ouch face keeps vanilla's inverted test, health minus the health of a
-- tic ago over 20 (st_oldhealth): so it shows when health jumps up while the
-- screen is still red from a hit, as in the original game.
-- Doom's counters are stored as tics (face_until, face_fire_since), so the
-- row changes only when the face does, not every tic: st_facecount at a
-- tic is face_until - level_tics (NULL: 0, a face of one tic, set again
-- while its condition holds), lastattackdown 70 tics after face_fire_since.
SELECT ps.health, ps.damage_count, ps.bonus_count, ps.god_mode, ps.invuln_tics,
       ps.face_patch, ps.face_until, ps.face_priority, ps.face_old_health, ps.face_fire_since,
       ps.face_weapons, ps.attacker_id, ps.position_x, ps.position_y, ps.view_angle, ps.level_tics,
       COALESCE((SELECT bit_or(1 << o.weapon_id) FROM player_weapon_owned o
                 WHERE o.map_id = ps.map_id AND o.player_thing_id = ps.player_thing_id), 0) AS weapons,
       COALESCE((SELECT g.attack_held FROM game_tic_commands g
                 WHERE g.map_id = ps.map_id AND g.player_thing_id = ps.player_thing_id), false) AS attack,
       a.x AS ax, a.y AS ay
INTO r
FROM player_state ps
LEFT JOIN things a ON a.map_id = ps.map_id AND a.id = ps.attacker_id
WHERE ps.map_id = doom_cs_face.p_map_id AND ps.player_thing_id = doom_cs_face.p_player_thing_id;
IF NOT FOUND THEN RETURN; END IF;

-- ST_calcPainOffset: health = min(health, 100); 5 * (100 - health) / 101
pain := 5 * (100 - LEAST(GREATEST(r.health, 0), 100)) / 101;
pri := r.face_priority; patch := r.face_patch;
cnt := COALESCE(r.face_until - r.level_tics, 0);   -- st_facecount
since := r.face_fire_since; ow := r.face_weapons;
IF ow < 0 THEN ow := r.weapons; END IF;       -- a spawn: ST_initData's oldweaponsowned

IF pri < 10 AND r.health <= 0 THEN
  pri := 9; patch := 'STFDEAD0'; cnt := 1;
END IF;
IF pri < 9 AND r.bonus_count > 0 AND r.weapons <> ow THEN
  ow := r.weapons;                             -- oldweaponsowned = weaponowned
  pri := 8; cnt := 70; patch := 'STFEVL' || pain;   -- ST_EVILGRINCOUNT, 2 s
END IF;
IF pri < 8 AND r.damage_count > 0 AND r.attacker_id IS NOT NULL
   AND r.attacker_id <> doom_cs_face.p_player_thing_id AND r.ax IS NOT NULL THEN
  pri := 7; cnt := 35;                         -- ST_TURNCOUNT, 1 s
  IF r.health - r.face_old_health > 20 THEN    -- ST_MUCHPAIN, vanilla's test
    patch := 'STFOUCH' || pain;
  ELSE
    -- the attacker's bearing from the facing, counter-clockwise, 0..360:
    -- within 45 degrees either way head-on (the rampage face), over 180 on
    -- the right (STFTR, "turn right"), else on the left
    d := mod((degrees(atan2(r.ay - r.position_y, r.ax - r.position_x)) - r.view_angle)::numeric + 720, 360)::double precision;
    patch := CASE WHEN d < 45 OR d > 315 THEN 'STFKILL' || pain
                  WHEN d > 180 THEN 'STFTR' || pain || '0'
                  ELSE 'STFTL' || pain || '0' END;
  END IF;
END IF;
IF pri < 7 AND r.damage_count > 0 THEN         -- hurt with no attacker
  IF r.health - r.face_old_health > 20 THEN
    pri := 7; cnt := 35; patch := 'STFOUCH' || pain;
  ELSE
    pri := 6; cnt := 35; patch := 'STFKILL' || pain;
  END IF;
END IF;
IF pri < 6 THEN                                -- fire held: the rampage face after 2 s
  IF r.attack THEN
    IF since IS NULL THEN
      since := r.level_tics;                   -- lastattackdown = ST_RAMPAGEDELAY
    ELSIF r.level_tics - since >= 70 THEN      -- --lastattackdown reached 0 (then 1, every tic)
      pri := 5; patch := 'STFKILL' || pain; cnt := 1;
    END IF;
  ELSE
    since := NULL;
  END IF;
END IF;
IF pri < 5 AND (r.god_mode OR r.invuln_tics > 0) THEN
  pri := 4; patch := 'STFGOD0'; cnt := 1;
END IF;
IF cnt <= 0 THEN                               -- looking around: st_randomnumber % 3
  patch := 'STFST' || pain || (doom_prandom(doom_cs_face.p_player_thing_id, r.level_tics, 43) % 3);
  cnt := 17; pri := 0;                         -- ST_STRAIGHTFACECOUNT, TICRATE / 2
END IF;
-- st_facecount-- : the face lasts cnt tics from this one. A face of one tic
-- (god, dead, rampage) is NULL: the same value every tic it is set again.
until_tic := CASE WHEN cnt <= 1 THEN NULL
                  -- a face kept from an earlier tic keeps its end
                  WHEN cnt = COALESCE(r.face_until - r.level_tics, 0) THEN r.face_until
                  ELSE r.level_tics + cnt END;

UPDATE player_state ps
SET face_patch = _cs.patch, face_until = _cs.until_tic, face_priority = _cs.pri,
    face_old_health = r.health, face_fire_since = _cs.since, face_weapons = _cs.ow
WHERE ps.map_id = doom_cs_face.p_map_id AND ps.player_thing_id = doom_cs_face.p_player_thing_id
  AND (ps.face_patch, ps.face_until, ps.face_priority, ps.face_old_health, ps.face_fire_since, ps.face_weapons)
      IS DISTINCT FROM (_cs.patch, _cs.until_tic, _cs.pri, r.health, _cs.since, _cs.ow);
END _cs;
$function$;
