-- Query 2b. Step 2: exactly one row per payment, the event with the latest modifiedDate.
-- Tie-breakers make the choice deterministic: a final status beats processing beats created,
-- then the earliest arrival.
-- Every payment-level query (turnover, failure rate, peak hours, Parquet) reads this view.
CREATE OR REPLACE VIEW payments AS
SELECT
  invoiceid, status, failurereason, amount, finalamount, ccy, reference,
  created_at, modified_at, received_at,
  merchantid, merchantname, mcc, customerid, paymentmethod, device,
  dt
FROM (
  SELECT
    e.*,
    row_number() OVER (
      PARTITION BY invoiceid
      ORDER BY modified_at DESC,
               CASE status WHEN 'success' THEN 3 WHEN 'failure' THEN 3
                           WHEN 'processing' THEN 2 ELSE 1 END DESC,
               received_at ASC
    ) AS rn
  FROM events e
) ranked
WHERE rn = 1
