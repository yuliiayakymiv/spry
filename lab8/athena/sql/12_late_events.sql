-- Query 6. Events that reached us more than 60 s after they happened
-- (processing time receivedAt minus event time modifiedDate), out of all events.
SELECT
  count_if(date_diff('second', modified_at, received_at) > 60)                          AS late_over_60s,
  count(*)                                                                              AS all_events,
  round(100.0 * count_if(date_diff('second', modified_at, received_at) > 60) / count(*), 3) AS late_pct,
  approx_percentile(date_diff('second', modified_at, received_at), 0.5)                 AS p50_delay_s,
  approx_percentile(date_diff('second', modified_at, received_at), 0.99)                AS p99_delay_s
FROM events
