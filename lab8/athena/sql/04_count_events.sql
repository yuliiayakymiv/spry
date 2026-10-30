-- Query 1 (check). Expect about 3 million rows and 31 partitions.
SELECT count(*) AS raw_events, count(DISTINCT dt) AS partitions
FROM payment_events
