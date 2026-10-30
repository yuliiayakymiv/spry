-- Part 4. A table over what Firehose wrote: s3://BUCKET/stream/dt=YYYY-MM-DD/*.gz (JSON Lines).
-- dt here is the ARRIVAL date in Firehose, not the payment date.
-- Partition projection: Athena computes the partitions itself, no MSCK REPAIR after every batch.
CREATE EXTERNAL TABLE IF NOT EXISTS payments_stream (
  invoiceid string, status string, failurereason string, amount bigint, finalamount bigint,
  ccy int, reference string, createddate string, modifieddate string, receivedat string,
  merchantid string, merchantname string, mcc string, customerid string,
  paymentmethod string, device string
)
PARTITIONED BY (dt string)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES ('ignore.malformed.json' = 'true')
LOCATION 's3://${BUCKET}/stream/'
TBLPROPERTIES (
  'projection.enabled'        = 'true',
  'projection.dt.type'        = 'date',
  'projection.dt.format'      = 'yyyy-MM-dd',
  'projection.dt.range'       = '2026-10-01,NOW',
  'storage.location.template' = 's3://${BUCKET}/stream/dt=${dt}/'
)
