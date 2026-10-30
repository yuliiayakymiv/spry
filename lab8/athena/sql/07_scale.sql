-- Answers about scale: unique payments, duplicates, events more than an hour late.
WITH raw AS (
  SELECT count(*) AS n FROM payment_events
),
ev AS (
  SELECT
    count(*)                                                        AS n,
    count(DISTINCT invoiceid)                                       AS unique_invoices,
    count_if(date_diff('second', modified_at, received_at) > 3600)  AS late_over_1h,
    max(date_diff('second', modified_at, received_at))              AS max_delay_s
  FROM events
)
SELECT
  raw.n                                       AS raw_events,
  ev.n                                        AS events_after_distinct,
  raw.n - ev.n                                AS exact_duplicates,
  round(100.0 * (raw.n - ev.n) / raw.n, 3)    AS duplicates_pct,
  ev.unique_invoices,
  ev.late_over_1h,
  round(100.0 * ev.late_over_1h / ev.n, 3)    AS late_over_1h_pct,
  ev.max_delay_s
FROM raw CROSS JOIN ev
