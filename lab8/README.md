# Lab 8 — Big Data on AWS

Batch (Athena + Glue) and stream (Redpanda locally, Kinesis in AWS) over the payments dataset.
Answers, run sheet and the results table: [docs/LAB8.md](../docs/LAB8.md).

| Folder / file | Part |
|---|---|
| `athena/` | 2 — table, dedup views, queries 3–7, Parquet CTAS, Glue Crawler, `run_athena.py` |
| `docker-compose.yml`, `producer.py`, `consumer.py`, `compare_windows.py` | 3 — Redpanda + Python |
| `cloud/` | 4 — Kinesis → Firehose → S3 → Athena, Kinesis → Lambda → SNS |
| `data/` (not in Git) | one day of events, consumer state and window CSVs |

```sh
pip install -r lab8/requirements.txt
```
