CREATE OR REPLACE FUNCTION doom.doom_mp_intermission_begin()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

UPDATE mp_match
SET state = 'intermission',
    intermission_until = now() + (CASE WHEN pending = 'final' THEN 30.0
                                       WHEN pending IN ('restart', 'rules', 'stay', 'solo') THEN 3.0
                                       ELSE intermission_tics::double precision / 35.0 END) * interval '1 second'
WHERE state = 'playing';
RETURN 1;
END _cs;
$function$;
