CREATE OR REPLACE FUNCTION doom.doom_demo_stop()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

UPDATE screen_state SET demo_playing=NULL, demo_recording=NULL, demo_tic=0 WHERE id=0;
RETURN;
END _cs;
$function$;
