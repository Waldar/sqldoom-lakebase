CREATE OR REPLACE FUNCTION doom.doom_menu_input(p_key text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  action text;
  _r1 record;
BEGIN

-- One keypress against the title/menu state machine
action := 'none';

FOR _r1 IN SELECT
  CASE
    WHEN s.screen='skill'  AND doom_menu_input.p_key='enter' THEN 'start'
    WHEN s.screen='main'   AND doom_menu_input.p_key='enter' AND s.cursor_index=5 THEN 'quit'
    WHEN s.screen='intermission' AND doom_menu_input.p_key IN ('enter','escape') THEN 'advance'
    WHEN s.screen='load' AND doom_menu_input.p_key='enter' AND EXISTS (
      SELECT 1 FROM save_slots v WHERE v.slot=s.cursor_index)
      THEN 'load:' || s.cursor_index::text
    WHEN s.screen='save' AND doom_menu_input.p_key='enter'
      THEN 'save:' || s.cursor_index::text
    ELSE 'none'
  END AS act
FROM screen_state s WHERE s.id=0
LOOP action := _r1.act; END LOOP;

UPDATE screen_state s
SET screen = CASE
      WHEN s.screen='title' THEN 'main'::screen_kind
      WHEN s.screen='main' AND doom_menu_input.p_key='enter' AND s.cursor_index=0 THEN 'episode'::screen_kind
      WHEN s.screen='main' AND doom_menu_input.p_key='enter' AND s.cursor_index=4 THEN 'help1'::screen_kind
      WHEN s.screen='help1' AND doom_menu_input.p_key='enter' THEN 'help2'::screen_kind
      WHEN s.screen='help2' AND doom_menu_input.p_key='enter' THEN 'main'::screen_kind
      WHEN s.screen IN ('help1','help2') AND doom_menu_input.p_key='escape' THEN 'main'::screen_kind
      WHEN s.screen='main' AND doom_menu_input.p_key='enter' AND s.cursor_index=2 THEN 'load'::screen_kind
      WHEN s.screen='main' AND doom_menu_input.p_key='enter' AND s.cursor_index=3 THEN 'save'::screen_kind
      WHEN s.screen IN ('load','save') AND doom_menu_input.p_key='escape' THEN 'main'::screen_kind
      WHEN s.screen='main' AND doom_menu_input.p_key='escape' THEN 'game'::screen_kind
      WHEN s.screen='save' AND doom_menu_input.p_key='enter' THEN 'game'::screen_kind
      WHEN s.screen='load' AND doom_menu_input.p_key='enter' AND EXISTS (
        SELECT 1 FROM save_slots v WHERE v.slot=s.cursor_index) THEN 'game'::screen_kind
      WHEN s.screen='episode' AND doom_menu_input.p_key='enter' THEN 'skill'::screen_kind
      WHEN s.screen='episode' AND doom_menu_input.p_key='escape' THEN 'main'::screen_kind
      WHEN s.screen='skill' AND doom_menu_input.p_key='escape' THEN 'episode'::screen_kind
      WHEN s.screen='skill' AND doom_menu_input.p_key='enter' THEN 'game'::screen_kind
      WHEN s.screen='intermission' AND doom_menu_input.p_key IN ('enter','escape') THEN 'game'::screen_kind
      ELSE s.screen
    END,
    cursor_index = CASE
      WHEN s.screen='title' THEN 0
      WHEN doom_menu_input.p_key='enter' AND s.screen='episode' THEN 2
      WHEN doom_menu_input.p_key='enter' AND ((s.screen='main' AND s.cursor_index IN (0,2,3))
                              OR s.screen IN ('skill','intermission',
                                              'load','save'))
        THEN 0
      WHEN s.screen IN ('help1','help2') THEN 4
      WHEN doom_menu_input.p_key='escape' AND s.screen='skill' THEN 0
      WHEN doom_menu_input.p_key='escape' AND s.screen IN ('episode','intermission',
                                           'load','save','main')
        THEN 0
      WHEN doom_menu_input.p_key='down' THEN (s.cursor_index + 1)
        % GREATEST(1,(SELECT count(*)::int FROM menu_items m WHERE m.screen=s.screen))
      WHEN doom_menu_input.p_key='up' THEN (s.cursor_index - 1
        + GREATEST(1,(SELECT count(*)::int FROM menu_items m WHERE m.screen=s.screen)))
        % GREATEST(1,(SELECT count(*)::int FROM menu_items m WHERE m.screen=s.screen))
      ELSE s.cursor_index
    END,
    episode = CASE WHEN s.screen='episode' AND doom_menu_input.p_key='enter'
                   THEN s.cursor_index + 1 ELSE s.episode END,
    -- Doom's skill runs 0..4; the tic pipeline wants the Thing option bit,
    -- which the client derives from this.
    skill = CASE WHEN s.screen='skill' AND doom_menu_input.p_key='enter'
                 THEN s.cursor_index ELSE s.skill END
WHERE s.id=0;

RETURN _cs.action;
END _cs;
$function$;
