-- Query 2a. Step 1 of deduplication: exact duplicates out (DISTINCT over every column),
-- and the three dates parsed once into UTC timestamps.
-- Every event-level question (duplicates, late events) reads this view.
CREATE OR REPLACE VIEW events AS
SELECT DISTINCT
  invoiceid,
  status,
  failurereason,
  amount,
  finalamount,
  ccy,
  reference,
  CAST(from_iso8601_timestamp(createddate)  AS timestamp) AS created_at,
  CAST(from_iso8601_timestamp(modifieddate) AS timestamp) AS modified_at,
  CAST(from_iso8601_timestamp(receivedat)   AS timestamp) AS received_at,
  merchantid,
  merchantname,
  mcc,
  customerid,
  paymentmethod,
  device,
  dt
FROM payment_events
