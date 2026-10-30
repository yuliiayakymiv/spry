-- Query 3 on Parquet. Turnover by merchant and currency, successful payments only, in major units.
-- finalAmount is in minor units (kopiyky, cents) -> divide by 100, as an exact decimal.
SELECT
  merchantid,
  merchantname,
  CASE ccy WHEN 980 THEN 'UAH' WHEN 840 THEN 'USD' WHEN 978 THEN 'EUR'
           ELSE CAST(ccy AS varchar) END                AS currency,
  count(*)                                              AS payments,
  CAST(sum(finalamount) AS decimal(20, 2)) / 100        AS turnover
FROM payments_parquet
WHERE status = 'success'
GROUP BY merchantid, merchantname, ccy
ORDER BY currency, turnover DESC
