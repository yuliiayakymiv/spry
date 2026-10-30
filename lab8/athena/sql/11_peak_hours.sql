-- Query 5. Payments per hour of the day (when the payment was created), Kyiv time.
-- Timestamps are stored in UTC; Athena's session zone is UTC.
SELECT
  hour(created_at AT TIME ZONE 'Europe/Kiev') AS hour_kyiv,
  count(*)                                    AS payments
FROM payments
GROUP BY 1
ORDER BY 1
