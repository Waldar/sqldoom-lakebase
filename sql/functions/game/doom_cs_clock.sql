CREATE OR REPLACE FUNCTION doom.doom_cs_clock(p_map_id integer, p_player_thing_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

-- One authoritative 35 Hz clock step
UPDATE player_state
SET level_tics=level_tics+1,
    pain_face_tics=GREATEST(0,pain_face_tics-1),
    radsuit_tics=GREATEST(0,radsuit_tics-1),
    invis_tics=GREATEST(0,invis_tics-1),
    light_amp_tics=GREATEST(0,light_amp_tics-1),
    invuln_tics=GREATEST(0,invuln_tics-1),
    -- P_PlayerThink: powers[pw_strength]++ while berserk (its red tint fades with it)
    berserk_tics=CASE WHEN berserk THEN LEAST(berserk_tics+1, 100000) ELSE 0 END,
    message_tics=GREATEST(0,message_tics-1),
    message=CASE WHEN message_tics<=1 THEN NULL ELSE message END,
    damage_count=GREATEST(0,damage_count-1),
    bonus_count=GREATEST(0,bonus_count-1)
WHERE map_id=doom_cs_clock.p_map_id::int AND player_thing_id=doom_cs_clock.p_player_thing_id::int;
RETURN;
END _cs;
$function$;
