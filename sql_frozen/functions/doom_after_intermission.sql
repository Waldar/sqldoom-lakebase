CREATE OR REPLACE FUNCTION doom.doom_after_intermission(p_map_id integer)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  nxt integer;
  ep integer;
  found integer;
  first integer;
  _r1 record;
  _r2 record;
BEGIN

nxt := -1;
ep := 1;
FOR _r1 IN SELECT COALESCE(s.next_map_id,-1) AS n, substring(m.name FROM 2 FOR 1)::int AS e
FROM screen_state s, maps m WHERE s.id=0 AND m.map_id=doom_after_intermission.p_map_id
LOOP nxt := _r1.n; ep := _r1.e; END LOOP;
IF _cs.nxt >= 0 THEN RETURN 'level:' || _cs.nxt::text; END IF;
found := doom_finale_begin(_cs.ep);
IF _cs.found <> 0 THEN RETURN 'finale'; END IF;
first := 1;
FOR _r2 IN SELECT MIN(map_id)::int AS f FROM maps
LOOP first := _r2.f; END LOOP;
RETURN 'level:' || _cs.first::text;
END _cs;
$function$;
