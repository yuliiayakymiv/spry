-- Query 1. The raw table: one row per webhook event, JSON Lines read straight from S3.
-- Dates stay strings here: they are ISO 8601 with a "Z" ("2026-10-01T08:15:22Z"), which the
-- JSON SerDe does not parse into TIMESTAMP reliably. The view `events` parses them once.
-- Athena lower-cases column names; the SerDe matches JSON keys case-insensitively
-- (invoiceId -> invoiceid).
CREATE EXTERNAL TABLE IF NOT EXISTS payment_events (
  invoiceid      string,
  status         string,
  failurereason  string,
  amount         bigint,
  finalamount    bigint,
  ccy            int,
  reference      string,
  createddate    string,
  modifieddate   string,
  receivedat     string,
  merchantid     string,
  merchantname   string,
  mcc            string,
  customerid     string,
  paymentmethod  string,
  device         string
)
PARTITIONED BY (dt string)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES ('ignore.malformed.json' = 'true')
LOCATION 's3://${BUCKET}/payments/'
