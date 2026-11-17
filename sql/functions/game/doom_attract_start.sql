CREATE OR REPLACE FUNCTION doom.doom_attract_start()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

-- A client that died mid-demo leaves demo_playing set; a fresh start owns it.
UPDATE screen_state
SET attract_step=0, attract_pagetic=170, screen='title', cursor_index=0,
    demo_playing=NULL, demo_recording=NULL, demo_tic=0
WHERE id=0;
RETURN;
END _cs;
$function$;
