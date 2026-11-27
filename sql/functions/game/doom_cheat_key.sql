CREATE OR REPLACE FUNCTION doom.doom_cheat_key(p_map_id integer, p_player_thing_id integer, p_key text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  buf text;
  result text;
  code text;
  msg text;
  _r1 record;
  _r2 record;
BEGIN

UPDATE screen_state SET cheat_buffer = RIGHT(cheat_buffer || UPPER(doom_cheat_key.p_key), 12) WHERE id=0;
buf := '';
FOR _r1 IN SELECT cheat_buffer AS b FROM screen_state WHERE id=0
LOOP buf := _r1.b; END LOOP;
result := 'none';
FOR _r2 IN SELECT CASE
  WHEN SUBSTRING(_cs.buf FROM LENGTH(_cs.buf)-7 FOR 6) = 'IDCLEV'
       AND SUBSTRING(_cs.buf FROM LENGTH(_cs.buf)-1 FOR 1) BETWEEN '1' AND '9'
       AND RIGHT(_cs.buf,1) BETWEEN '1' AND '9'
    THEN 'warp:E' || SUBSTRING(_cs.buf FROM LENGTH(_cs.buf)-1 FOR 1) || 'M' || RIGHT(_cs.buf,1)
  WHEN SUBSTRING(_cs.buf FROM LENGTH(_cs.buf)-6 FOR 5) = 'IDMUS'
       AND SUBSTRING(_cs.buf FROM LENGTH(_cs.buf)-1 FOR 1) BETWEEN '1' AND '9'
       AND RIGHT(_cs.buf,1) BETWEEN '1' AND '9'
    THEN 'music:E' || SUBSTRING(_cs.buf FROM LENGTH(_cs.buf)-1 FOR 1) || 'M' || RIGHT(_cs.buf,1)
  WHEN RIGHT(_cs.buf,4) = 'IDDT' THEN 'iddt'
  -- ST_Responder's cheat_powerup[6]: "idbehold" alone prints STSTR_BEHOLD
  -- and waits for the letter (2026-11-27; it printed nothing)
  WHEN RIGHT(_cs.buf,8) = 'IDBEHOLD' THEN 'prompt:inVuln, Str, Inviso, Rad, Allmap, or Lite-amp'
  ELSE COALESCE((
    SELECT 'code:' || c.code
    FROM (VALUES ('IDSPISPOPD'),('IDCHOPPERS'),('IDBEHOLDV'),('IDBEHOLDS'),
                 ('IDBEHOLDI'),('IDBEHOLDR'),('IDBEHOLDA'),('IDBEHOLDL'),
                 ('IDMYPOS'),('IDCLIP'),('IDKFA'),('IDDQD'),('IDFA')) AS c(code)
    WHERE _cs.buf LIKE '%' || c.code
    ORDER BY LENGTH(c.code) DESC, c.code LIMIT 1), 'none')
END AS r
LOOP result := _r2.r; END LOOP;
IF _cs.result LIKE 'code:%' THEN
  code := SUBSTRING(_cs.result FROM 6);
  msg := doom_cheat(doom_cheat_key.p_map_id, doom_cheat_key.p_player_thing_id, _cs.code);
  result := 'msg:' || _cs.msg;
END IF;
-- the prompt keeps the buffer: the next letter completes the code
IF _cs.result LIKE 'prompt:%' THEN
  RETURN 'msg:' || SUBSTRING(_cs.result FROM 8);
END IF;
IF _cs.result <> 'none' THEN
  UPDATE screen_state SET cheat_buffer='' WHERE id=0;
END IF;
RETURN _cs.result;
END _cs;
$function$;
