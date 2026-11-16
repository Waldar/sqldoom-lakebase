CREATE OR REPLACE FUNCTION doom.doom_mp_frags(p_map_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

UPDATE player_state k
SET frags = k.frags + 1,
    message = 'YOU FRAGGED ' || COALESCE(vs.display_name, 'PLAYER ' || vs.slot::text),
    message_tics = 140
FROM player_state v
JOIN mp_players vs ON vs.map_id=v.map_id AND vs.player_thing_id=v.player_thing_id
WHERE v.map_id=doom_mp_frags.p_map_id AND NOT v.alive AND v.killer_id IS NOT NULL
  AND v.killer_id >= 0 AND v.killer_id <> v.player_thing_id
  AND k.map_id=v.map_id AND k.player_thing_id=v.killer_id;

UPDATE player_state v
SET frags = v.frags - CASE WHEN v.killer_id = v.player_thing_id OR v.killer_id < 0
                           THEN 1 ELSE 0 END,
    message = CASE WHEN v.killer_id = v.player_thing_id THEN 'YOU KILLED YOURSELF'
                   WHEN v.killer_id < 0 THEN 'YOU DIED'
                   ELSE COALESCE(ks.display_name, 'PLAYER ' || ks.slot::text) || ' FRAGGED YOU' END,
    message_tics = 140,
    killer_id = NULL
FROM mp_players ks
WHERE v.map_id=doom_mp_frags.p_map_id AND NOT v.alive AND v.killer_id IS NOT NULL
  AND ks.map_id=v.map_id
  AND ks.player_thing_id = CASE WHEN v.killer_id >= 0 THEN v.killer_id
                                ELSE v.player_thing_id END;
RETURN;
END _cs;
$function$;
