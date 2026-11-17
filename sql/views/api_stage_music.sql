CREATE OR REPLACE VIEW doom.api_stage_music AS
 SELECT ma.name,
    ma.midi_data,
    ma.audio_data,
    ma.audio_format
   FROM (map_music mm
     JOIN music_assets ma ON (((ma.name)::text = (mm.music_name)::text)))
  WHERE (mm.map_id = ( SELECT mp.map_id
           FROM mp_players mp
          WHERE (mp.role_name = doom_caller())));
