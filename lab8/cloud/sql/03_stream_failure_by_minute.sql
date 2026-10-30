-- The same metric as the stream consumers, now in batch over the stream's output:
-- failure share per payment method per minute of EVENT time, after deduplication.
-- Unlike a streaming window, batch SQL sees late events no matter how late they were.
SELECT
  date_trunc('minute', CAST(from_iso8601_timestamp(modifieddate) AS timestamp)) AS minute_utc,
  paymentmethod,
  count(*)                                                    AS finished,
  count_if(status = 'failure')                                AS failed,
  round(100.0 * count_if(status = 'failure') / count(*), 1)   AS failure_pct
FROM (SELECT DISTINCT * FROM payments_stream)
WHERE status IN ('success', 'failure')
GROUP BY 1, 2
ORDER BY 1, 2
