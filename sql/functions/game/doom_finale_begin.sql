CREATE OR REPLACE FUNCTION doom.doom_finale_begin(p_episode integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  found integer;
  _r1 record;
BEGIN

-- F_StartFinale. Returns 1 when this episode has a finale to show and 0 when
-- it does not, which is the caller's cue to go straight back to the title
-- screen rather than sit on an empty page.
found := 0;
FOR _r1 IN SELECT COUNT(*) AS n FROM finale_defs WHERE episode = doom_finale_begin.p_episode::int
LOOP found := _r1.n; END LOOP;
IF _cs.found <> 0 THEN
  UPDATE screen_state
  SET screen='finale', finale_episode=doom_finale_begin.p_episode::int,
      finale_count=0, finale_stage=0, cursor_index=0
  WHERE id=0;
END IF;
RETURN _cs.found;
END _cs;
$function$;
