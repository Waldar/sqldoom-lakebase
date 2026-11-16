CREATE OR REPLACE FUNCTION doom.doom_finale_tic()
 RETURNS text
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  result text;
  _r1 record;
BEGIN

-- One 35 Hz step of F_Ticker. The page types out at TEXTSPEED (3 tics a
-- character) and then sits for TEXTWAIT (250 tics) before the episode's
-- ending picture replaces it.
--
-- Returns 'text' while the page is up, 'picture' once the ending art is, and
-- 'done' if something else has taken the screen.
result := 'text';

UPDATE screen_state s
SET finale_count = CASE WHEN d.advance THEN 0 ELSE s.finale_count + 1 END,
    finale_stage = CASE WHEN d.advance THEN 1 ELSE s.finale_stage END
FROM (
  SELECT s2.id,
         (s2.finale_stage = 0
          AND s2.finale_count + 1 > length(f.story_text) * 3 + 250) AS advance
  FROM screen_state s2
  JOIN finale_defs f ON f.episode = s2.finale_episode
  WHERE s2.id = 0 AND s2.screen = 'finale'
) d
WHERE s.id = d.id;

FOR _r1 IN SELECT CASE WHEN screen <> 'finale' THEN 'done'
            WHEN finale_stage = 0 THEN 'text'
            ELSE 'picture' END AS r
FROM screen_state WHERE id=0
LOOP result := _r1.r; END LOOP;
RETURN _cs.result;
END _cs;
$function$;
