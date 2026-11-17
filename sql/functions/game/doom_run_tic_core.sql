CREATE OR REPLACE FUNCTION doom.doom_run_tic_core(p_map_id integer, p_skill integer, p1 integer, p2 integer, p3 integer, p4 integer)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  act2 boolean;
  act3 boolean;
  act4 boolean;
  fired bigint;
  deathmatch boolean;
  has3 boolean;
  has4 boolean;
  plan1 bigint;
  plan2 bigint;
  plan3 bigint;
  plan4 bigint;
  plans bigint;
  sound_due boolean;
  use_queued boolean;
  u2 boolean;
  u3 boolean;
  u4 boolean;
  active bigint;
  did1 integer;
  d2 integer;
  d3 integer;
  d4 integer;
  pm integer;
  _r1 record;
BEGIN

-- Stage trace. Bits match dock.TIC_STAGES; see tic_trace in schema.sql.
fired := 1::bigint;
deathmatch := doom_run_tic_core.p2 IS NOT NULL;
has3 := doom_run_tic_core.p3 IS NOT NULL;
has4 := doom_run_tic_core.p4 IS NOT NULL;
act2 := _cs.deathmatch AND doom_slot_active(doom_run_tic_core.p_map_id, doom_run_tic_core.p2);
act3 := _cs.has3 AND doom_slot_active(doom_run_tic_core.p_map_id, doom_run_tic_core.p3);
act4 := _cs.has4 AND doom_slot_active(doom_run_tic_core.p_map_id, doom_run_tic_core.p4);
PERFORM doom_cs_clock(doom_run_tic_core.p_map_id,doom_run_tic_core.p1);
IF _cs.deathmatch THEN PERFORM doom_cs_clock(doom_run_tic_core.p_map_id,doom_run_tic_core.p2); END IF;
IF _cs.has3 THEN PERFORM doom_cs_clock(doom_run_tic_core.p_map_id,doom_run_tic_core.p3); END IF;
IF _cs.has4 THEN PERFORM doom_cs_clock(doom_run_tic_core.p_map_id,doom_run_tic_core.p4); END IF;
fired := _cs.fired | 2::bigint;
plan1 := doom_cs_plan(doom_run_tic_core.p_map_id,doom_run_tic_core.p1);
plan2 := 0::bigint;
plan3 := 0::bigint;
plan4 := 0::bigint;
IF _cs.act2 THEN plan2 := doom_cs_plan(doom_run_tic_core.p_map_id,doom_run_tic_core.p2); END IF;
IF _cs.act3 THEN plan3 := doom_cs_plan(doom_run_tic_core.p_map_id,doom_run_tic_core.p3); END IF;
IF _cs.act4 THEN plan4 := doom_cs_plan(doom_run_tic_core.p_map_id,doom_run_tic_core.p4); END IF;
fired := _cs.fired | 4::bigint;
plans := _cs.plan1 | _cs.plan2 | _cs.plan3 | _cs.plan4;
sound_due := (_cs.plans & 128) <> 0;
use_queued := doom_tic_use(doom_run_tic_core.p_map_id,doom_run_tic_core.p1,_cs.plan1);
IF _cs.act2 THEN u2 := doom_tic_use(doom_run_tic_core.p_map_id,doom_run_tic_core.p2,_cs.plan2); use_queued := _cs.use_queued OR _cs.u2; END IF;
IF _cs.act3 THEN u3 := doom_tic_use(doom_run_tic_core.p_map_id,doom_run_tic_core.p3,_cs.plan3); use_queued := _cs.use_queued OR _cs.u3; END IF;
IF _cs.act4 THEN u4 := doom_tic_use(doom_run_tic_core.p_map_id,doom_run_tic_core.p4,_cs.plan4); use_queued := _cs.use_queued OR _cs.u4; END IF;
IF (_cs.plans & 1) <> 0 THEN fired := _cs.fired | 8::bigint; END IF;
active := 0::bigint;
IF (_cs.plans & 2) <> 0 OR _cs.use_queued THEN
  active := doom_cs_activate_specials(doom_run_tic_core.p_map_id);
  fired := _cs.fired | 16::bigint;
END IF;
IF (_cs.plans & 4) <> 0 OR _cs.active <> 0 THEN
  PERFORM doom_cs_doors(doom_run_tic_core.p_map_id,doom_run_tic_core.p1);
  fired := _cs.fired | 32::bigint;
END IF;
-- The plan once carried a scroller bit here. Special-48 wall scrolling is a
-- function of level_tics that the renderer applies per frame, so there was
-- nothing to step, and the bit is gone rather than left as a hole.
did1 := doom_tic_move(doom_run_tic_core.p_map_id,doom_run_tic_core.p1);
IF _cs.did1 = 1 THEN fired := _cs.fired | 128::bigint; END IF;
IF _cs.did1 = 2 THEN fired := _cs.fired | 256::bigint; END IF;
IF _cs.act2 THEN d2 := doom_tic_move(doom_run_tic_core.p_map_id,doom_run_tic_core.p2); END IF;
IF _cs.act3 THEN d3 := doom_tic_move(doom_run_tic_core.p_map_id,doom_run_tic_core.p3); END IF;
IF _cs.act4 THEN d4 := doom_tic_move(doom_run_tic_core.p_map_id,doom_run_tic_core.p4); END IF;
-- After the movement stage, so nothing writes the standing eye height back
-- over the sinking one. A no-op while the player is alive.
PERFORM doom_cs_death(doom_run_tic_core.p_map_id,doom_run_tic_core.p1);
IF _cs.act2 THEN PERFORM doom_cs_death(doom_run_tic_core.p_map_id,doom_run_tic_core.p2); END IF;
IF _cs.act3 THEN PERFORM doom_cs_death(doom_run_tic_core.p_map_id,doom_run_tic_core.p3); END IF;
IF _cs.act4 THEN PERFORM doom_cs_death(doom_run_tic_core.p_map_id,doom_run_tic_core.p4); END IF;
plan1 := doom_cs_plan(doom_run_tic_core.p_map_id,doom_run_tic_core.p1);
IF _cs.act2 THEN plan2 := doom_cs_plan(doom_run_tic_core.p_map_id,doom_run_tic_core.p2); END IF;
IF _cs.act3 THEN plan3 := doom_cs_plan(doom_run_tic_core.p_map_id,doom_run_tic_core.p3); END IF;
IF _cs.act4 THEN plan4 := doom_cs_plan(doom_run_tic_core.p_map_id,doom_run_tic_core.p4); END IF;
plans := _cs.plan1 | _cs.plan2 | _cs.plan3 | _cs.plan4;
sound_due := _cs.sound_due OR (_cs.plans & 128) <> 0;
IF (_cs.plans & 8) <> 0 THEN fired := _cs.fired | 512::bigint | 1024::bigint | 2048::bigint; END IF;
plan1 := doom_tic_secrets(doom_run_tic_core.p_map_id,doom_run_tic_core.p1,_cs.plan1);
IF _cs.act2 THEN plan2 := doom_tic_secrets(doom_run_tic_core.p_map_id,doom_run_tic_core.p2,_cs.plan2); END IF;
IF _cs.act3 THEN plan3 := doom_tic_secrets(doom_run_tic_core.p_map_id,doom_run_tic_core.p3,_cs.plan3); END IF;
IF _cs.act4 THEN plan4 := doom_tic_secrets(doom_run_tic_core.p_map_id,doom_run_tic_core.p4,_cs.plan4); END IF;
plans := _cs.plan1 | _cs.plan2 | _cs.plan3 | _cs.plan4;
sound_due := _cs.sound_due OR (_cs.plans & 128) <> 0;
IF (_cs.plans & 16) <> 0 THEN fired := _cs.fired | 4096::bigint; END IF;
plan1 := doom_tic_weapon(doom_run_tic_core.p_map_id,doom_run_tic_core.p1,_cs.plan1);
IF _cs.act2 THEN plan2 := doom_tic_weapon(doom_run_tic_core.p_map_id,doom_run_tic_core.p2,_cs.plan2); END IF;
IF _cs.act3 THEN plan3 := doom_tic_weapon(doom_run_tic_core.p_map_id,doom_run_tic_core.p3,_cs.plan3); END IF;
IF _cs.act4 THEN plan4 := doom_tic_weapon(doom_run_tic_core.p_map_id,doom_run_tic_core.p4,_cs.plan4); END IF;
plans := _cs.plan1 | _cs.plan2 | _cs.plan3 | _cs.plan4;
sound_due := _cs.sound_due OR (_cs.plans & 128) <> 0;
IF (_cs.plans & 32) <> 0 THEN fired := _cs.fired | 8192::bigint | 16384::bigint; END IF;
-- World stages once. The projectile stage spawns every player's missiles and
-- tests every player as a target; the sound stage runs per player because its
-- player cues are keyed by player, while its world cues dedupe on their keys.
-- The player the world stages see: in a deathmatch a different live, held
-- slot every tic, so monsters notice everyone (doom_cs_monsters keeps the
-- target a monster picked; this only decides who is offered).
pm := doom_run_tic_core.p1;
IF _cs.deathmatch THEN
  FOR _r1 IN SELECT q.player_thing_id AS x
  FROM (SELECT mp.player_thing_id, ps.level_tics,
               ROW_NUMBER() OVER (ORDER BY mp.slot) AS rn, COUNT(*) OVER () AS n
        FROM mp_players mp
        JOIN player_state ps ON ps.map_id=mp.map_id AND ps.player_thing_id=mp.player_thing_id
        WHERE mp.map_id=doom_run_tic_core.p_map_id AND mp.role_name IS NOT NULL AND ps.alive) q
  WHERE q.rn = (q.level_tics % q.n) + 1
LOOP pm := _r1.x; END LOOP;
END IF;
IF (_cs.plans & 64) <> 0 THEN
  PERFORM doom_cs_projectiles(doom_run_tic_core.p_map_id,_cs.pm);
  fired := _cs.fired | 32768::bigint;
  plan1 := doom_cs_plan(doom_run_tic_core.p_map_id,doom_run_tic_core.p1);
  IF _cs.act2 THEN plan2 := doom_cs_plan(doom_run_tic_core.p_map_id,doom_run_tic_core.p2); END IF;
  IF _cs.act3 THEN plan3 := doom_cs_plan(doom_run_tic_core.p_map_id,doom_run_tic_core.p3); END IF;
  IF _cs.act4 THEN plan4 := doom_cs_plan(doom_run_tic_core.p_map_id,doom_run_tic_core.p4); END IF;
  sound_due := _cs.sound_due OR ((_cs.plan1 | _cs.plan2 | _cs.plan3 | _cs.plan4) & 128) <> 0;
END IF;
IF _cs.sound_due THEN
  PERFORM doom_cs_sound(doom_run_tic_core.p_map_id,doom_run_tic_core.p1);
  IF _cs.act2 THEN PERFORM doom_cs_sound(doom_run_tic_core.p_map_id,doom_run_tic_core.p2); END IF;
  IF _cs.act3 THEN PERFORM doom_cs_sound(doom_run_tic_core.p_map_id,doom_run_tic_core.p3); END IF;
  IF _cs.act4 THEN PERFORM doom_cs_sound(doom_run_tic_core.p_map_id,doom_run_tic_core.p4); END IF;
  fired := _cs.fired | 65536::bigint;
END IF;
PERFORM doom_cs_monsters(doom_run_tic_core.p_map_id,_cs.pm);
fired := _cs.fired | 131072::bigint;
IF _cs.deathmatch THEN PERFORM doom_cs_item_respawn(doom_run_tic_core.p_map_id,doom_run_tic_core.p1); END IF;
-- Animated sector lighting and damaging floors. Unconditional like the
-- monsters: it writes only the sectors whose value actually changed, so an
-- idle tic costs a comparison per animated sector and nothing else.
PERFORM doom_cs_sector_fx(doom_run_tic_core.p_map_id,doom_run_tic_core.p1);
IF _cs.act2 THEN PERFORM doom_cs_sector_fx(doom_run_tic_core.p_map_id,doom_run_tic_core.p2); END IF;
IF _cs.act3 THEN PERFORM doom_cs_sector_fx(doom_run_tic_core.p_map_id,doom_run_tic_core.p3); END IF;
IF _cs.act4 THEN PERFORM doom_cs_sector_fx(doom_run_tic_core.p_map_id,doom_run_tic_core.p4); END IF;
fired := _cs.fired | 262144::bigint;
-- P_XYMovement for Things, after the monsters have handed out their damage so
-- a shove given this tic is carried this tic. Reads nothing when nothing is
-- moving, which is almost always.
PERFORM doom_cs_thing_physics(doom_run_tic_core.p_map_id);
-- A_BossDeath, after the monsters have taken their damage for this tic so a
-- boss that died in it counts immediately. Cheap on every ordinary map: the
-- aggregate it runs has no group to work on unless the map is in
-- boss_actions.
PERFORM doom_cs_boss(doom_run_tic_core.p_map_id);
fired := _cs.fired | 524288::bigint;

IF _cs.deathmatch THEN
  -- Scoreboard once, then each player's pose and respawn.
  PERFORM doom_mp_frags(doom_run_tic_core.p_map_id);
  PERFORM doom_tic_dm_player(doom_run_tic_core.p_map_id,doom_run_tic_core.p1);
  PERFORM doom_tic_dm_player(doom_run_tic_core.p_map_id,doom_run_tic_core.p2);
  IF _cs.has3 THEN PERFORM doom_tic_dm_player(doom_run_tic_core.p_map_id,doom_run_tic_core.p3); END IF;
  IF _cs.has4 THEN PERFORM doom_tic_dm_player(doom_run_tic_core.p_map_id,doom_run_tic_core.p4); END IF;
END IF;

-- Most consecutive tics run exactly the same set of stages, and the client
-- re-reads this row every tic regardless, so skipping the unchanged writes
-- costs it nothing and saves a row version per tic.
INSERT INTO tic_trace (map_id,player_thing_id,stages)
VALUES (doom_run_tic_core.p_map_id::int,doom_run_tic_core.p1::int,_cs.fired)
ON CONFLICT (map_id,player_thing_id) DO UPDATE SET stages=EXCLUDED.stages
WHERE tic_trace.stages <> EXCLUDED.stages;

RETURN _cs.sound_due;
END _cs;
$function$;
