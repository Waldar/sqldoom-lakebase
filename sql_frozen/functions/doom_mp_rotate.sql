CREATE OR REPLACE FUNCTION doom.doom_mp_rotate()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  nxt integer;
  skill integer;
  _r1 record;
BEGIN

nxt := doom_mp_next_map();
DELETE FROM mp_map_request;
PERFORM doom_mp_apply_mode();
skill := 3;
FOR _r1 IN SELECT m.skill AS s FROM mp_match m
LOOP skill := _r1.s; END LOOP;
INSERT INTO mp_holders (slot, role_name, display_name, claimed_at)
SELECT mp.slot, mp.role_name, mp.display_name, mp.claimed_at FROM mp_players mp WHERE mp.role_name IS NOT NULL
ON CONFLICT (slot) DO UPDATE SET role_name = EXCLUDED.role_name, display_name = EXCLUDED.display_name,
  claimed_at = EXCLUDED.claimed_at;
DELETE FROM mp_holders h
WHERE NOT EXISTS (SELECT 1 FROM mp_players mp WHERE mp.slot = h.slot AND mp.role_name IS NOT NULL);
PERFORM doom_mp_start(_cs.nxt, _cs.skill);
-- The seat follows the player, and so does the time they have held it.
UPDATE mp_players mp
SET role_name = h.role_name, display_name = h.display_name, claimed_at = h.claimed_at,
    last_seen = now() + interval '15 seconds'
FROM mp_holders h
WHERE mp.map_id = _cs.nxt AND mp.slot = h.slot;
INSERT INTO mp_join_requests (map_id, slot)
SELECT _cs.nxt, h.slot FROM mp_holders h
WHERE EXISTS (SELECT 1 FROM mp_players mp WHERE mp.map_id = _cs.nxt AND mp.slot = h.slot)
ON CONFLICT DO NOTHING;
DELETE FROM mp_inputs;
UPDATE mp_match
SET map_id = _cs.nxt, state = 'playing', intermission_until = NULL, maps_played = maps_played + 1;
RETURN _cs.nxt;
END _cs;
$function$;
