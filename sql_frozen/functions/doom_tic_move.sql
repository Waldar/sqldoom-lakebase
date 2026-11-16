CREATE OR REPLACE FUNCTION doom.doom_tic_move(p_map_id integer, p integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  mode text;
  did integer;
BEGIN

mode := doom_cs_movement_mode(doom_tic_move.p_map_id,doom_tic_move.p);
did := 0;
IF _cs.mode = 'full' THEN PERFORM doom_cs_move(doom_tic_move.p_map_id,doom_tic_move.p); did := 1; END IF;
IF _cs.mode = 'turn' THEN PERFORM doom_cs_turn(doom_tic_move.p_map_id,doom_tic_move.p); did := 2; END IF;
RETURN _cs.did;
END _cs;
$function$;
