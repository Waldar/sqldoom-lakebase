CREATE OR REPLACE FUNCTION doom.doom_attract_stop()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

UPDATE screen_state
SET attract_step=-1,
    screen=CASE WHEN demo_playing IS NOT NULL THEN 'title'::screen_kind ELSE screen END,
    demo_playing=NULL, demo_tic=0
WHERE id=0;
RETURN;
END _cs;
$function$;
