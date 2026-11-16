CREATE OR REPLACE FUNCTION doom.doom_mp_next_map()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  cur_name text;
  next_id integer;
  _r1 record;
  _r2 record;
  _r3 record;
  _r4 record;
  _r5 record;
BEGIN

cur_name := ''; next_id := -1;
FOR _r1 IN SELECT ma.name AS n FROM mp_match m JOIN maps ma ON ma.map_id = m.map_id
LOOP cur_name := _r1.n; END LOOP;
FOR _r2 IN SELECT ma.map_id AS id
FROM mp_rotation r JOIN maps ma ON ma.name = r.map_name
WHERE r.position > COALESCE((SELECT r2.position FROM mp_rotation r2 WHERE r2.map_name = _cs.cur_name), -1)
ORDER BY r.position LIMIT 1
LOOP next_id := _r2.id; END LOOP;
IF _cs.next_id < 0 THEN
  FOR _r3 IN SELECT ma.map_id AS id FROM mp_rotation r JOIN maps ma ON ma.name = r.map_name
  ORDER BY r.position LIMIT 1
LOOP next_id := _r3.id; END LOOP;
END IF;
IF _cs.next_id < 0 THEN FOR _r4 IN SELECT m.map_id AS id FROM mp_match m
LOOP next_id := _r4.id; END LOOP; END IF;
FOR _r5 IN SELECT ma.map_id AS id FROM mp_map_request q JOIN maps ma ON ma.name = q.map_name
LOOP next_id := _r5.id; END LOOP;
RETURN _cs.next_id;
END _cs;
$function$;
