-- The per-player frame views: 5 kinds (frame, indexed frame, low-detail indexed
-- frame, status bar, status-bar cache key) for every map and player slot. Each
-- view has its map, slot and player start written in as literals, so its plan
-- is specific to one player. The player starts are the Things of type 1 to 4
-- (the slot number). Returns the number of views created.
CREATE OR REPLACE FUNCTION doom.create_frame_views()
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO doom, public
AS $function$
DECLARE
  k record;
  p record;
  v text;
  n integer := 0;
BEGIN
  FOR p IN SELECT t.map_id, t.type AS slot, t.id AS thing_id
           FROM doom.things t WHERE t.type BETWEEN 1 AND 4
           ORDER BY t.map_id, t.type LOOP
    FOR k IN SELECT * FROM (VALUES
               ('api_frame_slot%s_m%s',         doom.frame_view_template_api_frame()),
               ('api_frame_idx_slot%s_m%s',     doom.frame_view_template_api_frame_idx()),
               ('api_frame_idx_slot%s_m%s_low', doom.frame_view_template_api_frame_idx_low()),
               ('doom_hud_slot%s_m%s',          doom.frame_view_template_hud()),
               ('doom_hudkey_slot%s_m%s',       doom.frame_view_template_hudkey())) kinds(pattern, template) LOOP
      v := format(k.pattern, p.slot, p.map_id);
      -- dropped first: CREATE OR REPLACE VIEW cannot change a view's columns
      EXECUTE format('DROP VIEW IF EXISTS doom.%I', v);
      EXECUTE replace(replace(replace(replace(k.template,
                '{name}', v), '{map_id}', p.map_id::text),
                '{slot}', p.slot::text), '{thing_id}', p.thing_id::text);
      n := n + 1;
    END LOOP;
  END LOOP;
  RETURN n;
END;
$function$;
