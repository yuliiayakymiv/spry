-- Query 2 (result). One row per payment: how many ended in each status.
SELECT status, count(*) AS payments, round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM payments
GROUP BY status
ORDER BY payments DESC
