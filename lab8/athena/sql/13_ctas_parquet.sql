-- Query 7. The deduplicated payments written once as Parquet, partitioned by dt, under curated/.
-- CTAS fails if the table or the S3 prefix already exists: to re-run, DROP TABLE payments_parquet
-- and delete s3://${BUCKET}/curated/payments/ first.
CREATE TABLE payments_parquet
WITH (
  format            = 'PARQUET',
  write_compression = 'SNAPPY',
  external_location = 's3://${BUCKET}/curated/payments/',
  partitioned_by    = ARRAY['dt']
) AS
SELECT * FROM payments
