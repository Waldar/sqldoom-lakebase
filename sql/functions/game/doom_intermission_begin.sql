CREATE OR REPLACE FUNCTION doom.doom_intermission_begin(p_map_id integer, p_player_thing_id integer, p_secret_exit boolean)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  next_id integer;
  _r1 record;
BEGIN

-- Enter the intermission for a finished level and work out what comes next.
next_id := -1;

WITH cur AS (
  SELECT m.map_id, m.name,
         substring(m.name FROM 2 FOR 1)::int AS ep,
         substring(m.name FROM 4 FOR 1)::int AS lv
  FROM maps m WHERE m.map_id = doom_intermission_begin.p_map_id::int
),
route AS (
  SELECT c.*,
    CASE
      WHEN doom_intermission_begin.p_secret_exit::boolean THEN 9
      WHEN c.lv = 9 THEN
        CASE c.ep WHEN 1 THEN 4 WHEN 2 THEN 6 WHEN 3 THEN 7 ELSE 3 END
      WHEN c.lv = 8 THEN NULL
      ELSE c.lv + 1
    END AS next_lv
  FROM cur c
),
resolved AS (
  SELECT r.*,
         (SELECT n.map_id FROM maps n
           WHERE n.name = 'E' || r.ep::text || 'M' || r.next_lv::text) AS next_id
  FROM route r
),
stats AS (
  SELECT ls.*,
         -- Doom divides by the level totals; a level holding none of a thing
         -- shows zero rather than dividing by zero.
         CASE WHEN ls.total_kills   > 0
              THEN LEAST(100, ls.kills   * 100 / ls.total_kills)   ELSE 0 END AS pk,
         CASE WHEN ls.total_items   > 0
              THEN LEAST(100, ls.items   * 100 / ls.total_items)   ELSE 0 END AS pi,
         CASE WHEN ls.total_secrets > 0
              THEN LEAST(100, ls.secrets * 100 / ls.total_secrets) ELSE 0 END AS ps
  FROM level_stats ls
  WHERE ls.map_id = doom_intermission_begin.p_map_id::int AND ls.player_thing_id = doom_intermission_begin.p_player_thing_id::int
)
UPDATE screen_state s
SET screen='intermission', cursor_index=0,
    inter_episode=r.ep, inter_level=r.lv,
    inter_next=COALESCE(r.next_lv, r.lv),
    next_map_id=r.next_id, secret_exit=doom_intermission_begin.p_secret_exit::boolean,
    tgt_kills=st.pk, tgt_items=st.pi, tgt_secrets=st.ps,
    tgt_time=(st.level_tics/35)::int,
    tgt_par=COALESCE((st.par_tics/35)::int, 0),
    kills_pct=0, items_pct=0, secrets_pct=0, time_secs=0, par_secs=0,
    sp_state=1, cnt_pause=35, accelerate=FALSE
FROM resolved r, stats st
WHERE s.id=0;

FOR _r1 IN SELECT COALESCE(MIN(next_map_id), -1) AS n FROM screen_state WHERE id=0
LOOP next_id := _r1.n; END LOOP;
RETURN _cs.next_id;
END _cs;
$function$;
