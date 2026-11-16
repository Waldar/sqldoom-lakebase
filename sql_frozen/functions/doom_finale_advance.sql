CREATE OR REPLACE FUNCTION doom.doom_finale_advance()
 RETURNS text
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  result text;
  stage integer;
  count integer;
  typed integer;
  _r1 record;
BEGIN

-- A keypress during the finale.
result := 'text';
stage := 0;
count := 0;
typed := 0;
FOR _r1 IN SELECT s.finale_stage AS st, s.finale_count AS c,
       COALESCE(length(f.story_text), 0) * 3 + 10 AS t
FROM screen_state s
LEFT JOIN finale_defs f ON f.episode = s.finale_episode
WHERE s.id = 0
LOOP stage := _r1.st; count := _r1.c; typed := _r1.t; END LOOP;

IF _cs.stage <> 0 THEN
  UPDATE screen_state
  SET screen='title', finale_stage=0, finale_count=0, finale_episode=NULL,
      cursor_index=0
  WHERE id=0;
  result := 'done';
END IF;
IF _cs.stage = 0 AND _cs.count < _cs.typed THEN
  -- Still typing: put the whole page up at once, leaving the wait to run.
  UPDATE screen_state SET finale_count=_cs.typed WHERE id=0;
  result := 'text';
END IF;
IF _cs.stage = 0 AND _cs.count >= _cs.typed THEN
  UPDATE screen_state SET finale_stage=1, finale_count=0 WHERE id=0;
  result := 'picture';
END IF;
RETURN _cs.result;
END _cs;
$function$;
