CREATE OR REPLACE VIEW doom.api_tic AS
 SELECT tic_ms,
    tic_p90_ms,
    tic_max_ms,
    tics,
    dropped,
    interval_seconds,
    (EXTRACT(epoch FROM (now() - updated_at)))::real AS age_seconds
   FROM api_tic_stats
  WHERE (id = 1);
