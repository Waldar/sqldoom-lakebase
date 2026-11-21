-- The caller's map's track; in single player, between two levels, Doom's
-- intermission music (D_INTER, WI_Ticker) and at the end of the episode its
-- victory music (D_VICTOR, F_StartFinale) while those screens are up
-- (doom_solo_screen_tic, 2026-11-21).
CREATE OR REPLACE VIEW doom.api_stage_music AS
 SELECT ma.name,
    ma.midi_data,
    ma.audio_data,
    ma.audio_format
   FROM music_assets ma
  WHERE ((ma.name)::text = COALESCE(( SELECT
                CASE ss.screen
                    WHEN 'intermission'::screen_kind THEN 'D_INTER'::text
                    ELSE 'D_VICTOR'::text
                END AS name
           FROM (screen_state ss
             JOIN mp_match m ON ((m.mode = 'solo'::text)))
          WHERE ((ss.id = 0) AND (ss.screen = ANY (ARRAY['intermission'::screen_kind, 'finale'::screen_kind])))
         LIMIT 1), ( SELECT (mm.music_name)::text AS music_name
           FROM map_music mm
          WHERE (mm.map_id = ( SELECT mp.map_id
                   FROM mp_players mp
                  WHERE (mp.role_name = doom_caller())))
         LIMIT 1)));
