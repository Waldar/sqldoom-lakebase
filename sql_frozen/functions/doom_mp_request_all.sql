CREATE OR REPLACE FUNCTION doom.doom_mp_request_all(p_map_id integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

INSERT INTO mp_join_requests (map_id, slot)
SELECT mp.map_id, mp.slot FROM mp_players mp WHERE mp.map_id=doom_mp_request_all.p_map_id
ON CONFLICT DO NOTHING;
RETURN 1;
END _cs;
$function$;
