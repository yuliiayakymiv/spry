-- Query 4 on Parquet. Share of failed payments per payment method and device, highest first.
-- Denominator = payments that reached a final status (success or failure).
SELECT
  paymentmethod,
  device,
  count(*)                                                       AS finished_payments,
  count_if(status = 'failure')                                   AS failed,
  round(100.0 * count_if(status = 'failure') / count(*), 2)      AS failure_pct
FROM payments_parquet
WHERE status IN ('success', 'failure')
GROUP BY paymentmethod, device
ORDER BY failure_pct DESC
