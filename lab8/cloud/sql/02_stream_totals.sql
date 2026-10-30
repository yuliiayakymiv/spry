-- What came through the stream: events, payments, duplicates, Firehose files, time span.
SELECT
  count(*)                              AS events,
  count(DISTINCT invoiceid)             AS payments,
  count(*) - (SELECT count(*) FROM (SELECT DISTINCT * FROM payments_stream)) AS exact_duplicates,
  count(DISTINCT "$path")               AS firehose_files,
  min(receivedat)                       AS first_received,
  max(receivedat)                       AS last_received
FROM payments_stream
