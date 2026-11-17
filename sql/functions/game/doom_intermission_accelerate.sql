CREATE OR REPLACE FUNCTION doom.doom_intermission_accelerate()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

-- A keypress during the tally. Doom's acceleratestage: it snaps the current
-- figure to its target, and once everything is shown it leaves the screen.
UPDATE screen_state SET accelerate=TRUE WHERE id=0;
RETURN 0;
END _cs;
$function$;
