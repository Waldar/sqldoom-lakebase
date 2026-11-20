CREATE OR REPLACE FUNCTION doom.doom_cs_monster_attack(p_map_id integer, p_player_thing_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  attack_range_default double precision;
  hitscan_spread double precision;
  shadow_miss double precision;
  melee_reach double precision;
  player_radius double precision;
BEGIN

-- 5 constants in one scan (was 5 doom_const() calls)
SELECT
       COALESCE(max(value) FILTER (WHERE name = 'DEFAULT_ATTACK_RANGE'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'HITSCAN_SPREAD_UNITS'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'SHADOW_MISS_UNITS'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'MELEE_REACH'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'PLAYER_RADIUS'), 0)
  INTO attack_range_default, hitscan_spread, shadow_miss, melee_reach, player_radius
  FROM doom_constants WHERE name IN ('DEFAULT_ATTACK_RANGE', 'HITSCAN_SPREAD_UNITS', 'MELEE_REACH', 'PLAYER_RADIUS', 'SHADOW_MISS_UNITS');

DELETE FROM monster_attack_damage WHERE map_id = doom_cs_monster_attack.p_map_id;
WITH
params AS NOT MATERIALIZED (SELECT doom_cs_monster_attack.p_map_id::int AS map_id, doom_cs_monster_attack.p_player_thing_id::int AS player_thing_id),
player_pos AS (
  SELECT pp.px, pp.py
  FROM doom_player_pos pp JOIN params p ON pp.map_id = p.map_id
   AND pp.player_thing_id = p.player_thing_id
),
-- Every live player on the map. A monster attacks the one it is angry with
-- (mon_target below); a barrel's blast reaches all of them.
players AS (
  SELECT ps.player_thing_id, t.x::double precision AS px, t.y::double precision AS py
  FROM player_state ps JOIN params p ON ps.map_id = p.map_id
  JOIN things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
  WHERE ps.alive
),
targets AS (
  SELECT player_thing_id, px, py FROM players
  UNION ALL
  SELECT p.player_thing_id, pp.px, pp.py
  FROM params p CROSS JOIN player_pos pp
  WHERE NOT EXISTS (SELECT 1 FROM players q
                    WHERE q.player_thing_id = p.player_thing_id)
),
-- MF_SHADOW on the target, which for the player means the blur sphere.
shadow AS (
  SELECT sh.shadowed, sh.level_tics
  FROM doom_player_shadow sh JOIN params p ON sh.map_id = p.map_id
   AND sh.player_thing_id = p.player_thing_id
),
attackers AS (
  SELECT a.thing_id, a.type, a.mx, a.my,
         a.hitscan_pellets, a.hitscan_mult, a.hitscan_sides,
         a.melee_mult, a.melee_sides, a.explodes,
         a.blast_radius
  FROM doom_monster_attackers a JOIN params p ON a.map_id = p.map_id
),
blocking_walls AS (
  SELECT ld.x1::double precision AS x1, ld.y1::double precision AS y1,
         ld.x2::double precision AS x2, ld.y2::double precision AS y2
  FROM linedef_geom ld JOIN params p ON ld.map_id = p.map_id
  LEFT JOIN sectors fr ON fr.map_id = ld.map_id AND fr.id = ld.fsec
  LEFT JOIN sectors bk ON bk.map_id = ld.map_id AND bk.id = ld.bsec
  -- Recheck live portal geometry on the attack frame. This prevents a shot
  -- already being animated from damaging the player after its door closes.
  WHERE ld.left_sd_id = -1 OR ld.right_sd_id = -1
     OR fr.id IS NULL OR bk.id IS NULL
     OR LEAST(fr.ceil_height, bk.ceil_height)
          <= GREATEST(fr.floor_height, bk.floor_height)
),
mon_target AS (
  SELECT ai.thing_id,
         COALESCE(tt.x::double precision, pp.px) AS tx,
         COALESCE(tt.y::double precision, pp.py) AS ty,
         CASE WHEN th.thing_id IS NULL THEN NULL ELSE ai.target_thing_id END
           AS victim_id,
         COALESCE(tp.player_thing_id, pp.player_thing_id) AS victim_player
  FROM monster_ai ai
  JOIN params p ON ai.map_id = p.map_id
  JOIN things at ON at.map_id = ai.map_id AND at.id = ai.thing_id
  JOIN thing_combat_defs acd ON acd.thing_type = at.type
  JOIN targets pp ON (acd.explodes OR pp.player_thing_id = p.player_thing_id)
  LEFT JOIN things tt ON tt.map_id = ai.map_id AND tt.id = ai.target_thing_id
  LEFT JOIN thing_health th ON th.map_id = ai.map_id
   AND th.thing_id = ai.target_thing_id AND th.alive
  LEFT JOIN player_state tp ON tp.map_id = ai.map_id
   AND tp.player_thing_id = ai.target_thing_id AND tp.alive
),
hits AS (
  SELECT a.thing_id, a.type, a.hitscan_pellets, a.hitscan_mult, a.hitscan_sides,
    a.melee_mult, a.melee_sides, a.explodes,
    a.blast_radius,
    mt.victim_id, mt.victim_player, sh.level_tics AS tic,
    sqrt(power(a.mx - pp.px, 2) + power(a.my - pp.py, 2)) AS dist,
    NOT EXISTS (
      SELECT 1 FROM blocking_walls b
      CROSS JOIN LATERAL (
        SELECT
          (a.mx - b.x1) * (b.y2 - b.y1) - (a.my - b.y1) * (b.x2 - b.x1) AS d1,
          (pp.px - b.x1) * (b.y2 - b.y1) - (pp.py - b.y1) * (b.x2 - b.x1) AS d2,
          (b.x1 - a.mx) * (pp.py - a.my) - (b.y1 - a.my) * (pp.px - a.mx) AS d3,
          (b.x2 - a.mx) * (pp.py - a.my) - (b.y2 - a.my) * (pp.px - a.mx) AS d4
      ) sides
      WHERE (sides.d1 * sides.d2 < 0) AND (sides.d3 * sides.d4 < 0)
    ) AS visible
  FROM attackers a
  CROSS JOIN shadow sh
  JOIN mon_target mt ON mt.thing_id = a.thing_id
  CROSS JOIN LATERAL (SELECT mt.tx AS px, mt.ty AS py) pp
),
pellet_random AS (
  SELECT h.thing_id,h.type,h.victim_id,h.victim_player,h.dist,h.visible,g.pellet,
         doom_prandom(h.thing_id, h.tic * 8 + g.pellet, 12) AS r1,
         doom_prandom(h.thing_id, h.tic * 8 + g.pellet, 13) AS r2,
         (doom_prandom(h.thing_id, h.tic * 8 + g.pellet, 14)
            % h.hitscan_sides + 1) * h.hitscan_mult
           AS pellet_damage,

         CASE WHEN sh.shadowed
              THEN (doom_prandom(h.thing_id, h.tic, 15)
                   -doom_prandom(h.thing_id, h.tic, 16))*360.0/_cs.shadow_miss
              ELSE 0.0 END AS shadow_err
  FROM hits h
  CROSS JOIN shadow sh
  CROSS JOIN LATERAL generate_series(1, h.hitscan_pellets) g(pellet)
  WHERE h.hitscan_pellets IS NOT NULL
),
damage AS (
  SELECT thing_id, victim_id, victim_player,
    CASE WHEN visible AND dist<=_cs.attack_range_default
           AND (dist<=_cs.player_radius OR
             ABS((r1-r2)*360.0/_cs.hitscan_spread + shadow_err)
               <=DEGREES(ASIN(LEAST(1.0,_cs.player_radius/NULLIF(dist,0.0)))))
         THEN pellet_damage ELSE 0 END AS dmg
  FROM pellet_random
  UNION ALL
  SELECT thing_id, victim_id, victim_player,
    CASE
      -- The bite at MELEERANGE (A_TroopAttack, A_SargAttack, A_HeadAttack,
      -- A_BruisAttack): melee_mult * (1..melee_sides) from the catalogue. A
      -- line attack, so the thing has to see its target.
      WHEN melee_mult IS NOT NULL AND visible AND dist<=_cs.melee_reach
        THEN (doom_prandom(thing_id, tic, 17) % melee_sides + 1)*melee_mult
      -- The barrel's blast falls off with distance.
      WHEN explodes AND visible AND dist<blast_radius
        THEN GREATEST(0,blast_radius-FLOOR(dist)::int)::int
      ELSE 0
    END AS dmg
  FROM hits WHERE melee_mult IS NOT NULL OR explodes
)
INSERT INTO monster_attack_damage
  (map_id, attacker_id, victim_id, victim_player, dmg, mx, my)
SELECT doom_cs_monster_attack.p_map_id::int, d.thing_id, d.victim_id, d.victim_player, d.dmg,
       a.mx, a.my
FROM damage d
JOIN attackers a ON a.thing_id = d.thing_id;

-- the staged rolls landing on a player
WITH
params AS NOT MATERIALIZED (SELECT doom_cs_monster_attack.p_map_id::int AS map_id, doom_cs_monster_attack.p_player_thing_id::int AS player_thing_id),
-- Every live player on the map. The shove joins this, so a roll staged
-- against a player who has since died lands on nobody.
players AS (
  SELECT ps.player_thing_id, t.x::double precision AS px, t.y::double precision AS py
  FROM player_state ps JOIN params p ON ps.map_id = p.map_id
  JOIN things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
  WHERE ps.alive
),
-- P_DamageMobj's `if (player && gameskill == sk_baby) damage >>= 1`, which
-- runs per hit and before the armour absorbs its third or half. Monster
-- victims (victim_id NOT NULL, the infighting path) never get it.
hurt AS (
  SELECT d.dmg >> CASE WHEN g.skill=0 THEN 1 ELSE 0 END AS dmg,
         d.mx, d.my, d.victim_player
  FROM monster_attack_damage d
  JOIN params p ON d.map_id = p.map_id
  JOIN game_tic_commands g ON g.map_id = p.map_id
   AND g.player_thing_id = d.victim_player
  WHERE d.victim_id IS NULL
),
-- P_DamageMobj shoves the player exactly as it shoves a monster:
-- `thrust = damage*(FRACUNIT>>3)*100/mass` directed away from the inflictor,
-- which for a bullet or a claw is the attacker itself. MT_PLAYER's mass is
-- 100, so the shove is damage/8 map units per tic. It is computed from the
-- damage before the armour absorbs any of it, and it is summed per hit --
-- three shotgun pellets from the same sergeant push three times as hard as
-- one.
shove AS (
  SELECT h.dmg, h.victim_player,
         CASE WHEN r.dist > 0 THEN h.dmg * 0.125 * r.ddx / r.dist
              ELSE 0.0 END AS tx,
         CASE WHEN r.dist > 0 THEN h.dmg * 0.125 * r.ddy / r.dist
              ELSE 0.0 END AS ty
  FROM hurt h
  JOIN players pp ON pp.player_thing_id = h.victim_player
  CROSS JOIN LATERAL (
    SELECT pp.px - h.mx AS ddx, pp.py - h.my AS ddy,
           sqrt(power(pp.px - h.mx, 2) + power(pp.py - h.my, 2)) AS dist
  ) r
),
totaled AS (
  SELECT doom_cs_monster_attack.p_map_id::int AS map_id, victim_player AS player_thing_id,
         SUM(dmg)::int AS total_dmg,
         SUM(FLOOR(dmg/3.0))::int AS green_saved,
         SUM(FLOOR(dmg/2.0))::int AS blue_saved,
         -- 16.16 fixed point, as vanilla accumulates momentum: a float sum of
         -- several hits would depend on the order the rows arrive in.
         SUM(ROUND(tx * 65536.0)) / 65536.0 AS thrust_x,
         SUM(ROUND(ty * 65536.0)) / 65536.0 AS thrust_y
  FROM shove
  GROUP BY victim_player
),
absorbed AS (
  SELECT t.*,
         (ps.god_mode OR ps.invuln_tics > 0) AS blocked,
         CASE WHEN ps.god_mode OR ps.invuln_tics > 0 THEN 0
              ELSE LEAST(ps.armor, CASE ps.armor_class
                     WHEN 2 THEN t.blue_saved WHEN 1 THEN t.green_saved
                     ELSE 0 END)
         END AS saved
  FROM totaled t
  JOIN player_state ps ON ps.map_id = t.map_id AND ps.player_thing_id = t.player_thing_id
),
applied AS (
  SELECT a.*, CASE WHEN a.blocked THEN 0 ELSE a.total_dmg - a.saved END AS took
  FROM absorbed a
)
UPDATE player_state ps
SET armor = ps.armor - a.saved,
    armor_class=CASE WHEN ps.armor-a.saved<=0 THEN 0 ELSE ps.armor_class END,
    health = GREATEST(0, ps.health - a.took),
    -- the killing blow's unclamped health: a gib below -100 (migration 0003)
    death_health = CASE WHEN ps.alive AND ps.health - a.took <= 0 THEN ps.health - a.took
                        ELSE ps.death_health END,
    -- P_DamageMobj: player->damagecount += damage, which reddens the screen.
    damage_count = LEAST(100, ps.damage_count + a.took),
    alive = GREATEST(0, ps.health - a.took) > 0,
    -- Renderer shows the STFOUCH pain face while this is > 0; a fresh hit
    -- always resets it to a full flash.
    pain_face_tics = CASE WHEN a.took > 0 THEN 12
                          ELSE ps.pain_face_tics END,
    -- A monster or a barrel is the world, for the deathmatch scoreboard.
    killer_id = CASE WHEN ps.alive AND ps.health - a.took <= 0 THEN -1
                     ELSE ps.killer_id END,
    momentum_x = (ps.momentum_x + a.thrust_x)::real,
    momentum_y = (ps.momentum_y + a.thrust_y)::real
FROM applied a
WHERE ps.map_id = a.map_id AND ps.player_thing_id = a.player_thing_id;

-- the same rolls, landing on a monster
UPDATE thing_health h
SET health = h.health - v.dmg, alive = h.health - v.dmg > 0
FROM (
  SELECT victim_id, SUM(dmg)::int AS dmg
  FROM monster_attack_damage
  WHERE map_id = doom_cs_monster_attack.p_map_id::int AND victim_id IS NOT NULL
    AND victim_player = doom_cs_monster_attack.p_player_thing_id::int
  GROUP BY victim_id
) v
WHERE h.map_id = doom_cs_monster_attack.p_map_id::int AND h.thing_id = v.victim_id AND v.dmg > 0;

-- the victim turns on whoever shot it
UPDATE monster_ai ai
SET target_thing_id = v.attacker,
    state = CASE WHEN ai.state = 'stand' THEN 'see'::actor_state ELSE ai.state END,
    seq_index = CASE WHEN ai.state = 'stand' THEN 0 ELSE ai.seq_index END,
    state_tics = CASE WHEN ai.state = 'stand' THEN 0 ELSE ai.state_tics END
FROM (
  SELECT victim_id, MIN(attacker_id) AS attacker
  FROM monster_attack_damage
  WHERE map_id = doom_cs_monster_attack.p_map_id::int AND victim_id IS NOT NULL AND dmg > 0
    AND victim_player = doom_cs_monster_attack.p_player_thing_id::int
  GROUP BY victim_id
) v
WHERE ai.map_id = doom_cs_monster_attack.p_map_id::int AND ai.thing_id = v.victim_id
  AND ai.thing_id <> v.attacker
  AND ai.target_thing_id IS DISTINCT FROM v.attacker
  AND EXISTS (SELECT 1 FROM thing_health th
              WHERE th.map_id = ai.map_id AND th.thing_id = ai.thing_id
                AND th.alive);
RETURN;
END _cs;
$function$;
