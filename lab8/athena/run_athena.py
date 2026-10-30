"""Run the Lab 8 Athena queries in order and keep the evidence.

For every sql/NN_*.sql file: substitute ${BUCKET}, run it in Athena, wait, then
  - save the result of a SELECT to results/NN_name.csv,
  - append run time and Data scanned to results/stats.md (the JSON vs Parquet comparison).

    python lab8/athena/run_athena.py --bucket lab8-payments-123456789012
    python lab8/athena/run_athena.py --bucket ... --only 09 10 11 14 15 16   # just re-run some
    python lab8/athena/run_athena.py --bucket ... --dir cloud/sql            # Part 4 queries

Needs: AWS CLI credentials (`aws configure`), `pip install boto3`.
"""

import argparse
import datetime as dt
import pathlib
import sys
import time

import boto3

HERE = pathlib.Path(__file__).resolve().parent
LAB8 = HERE.parent
DATABASE = "lab8"


def run(athena, sql: str, bucket: str, database: str) -> dict:
    """Start one query, poll until it ends, return the QueryExecution description."""
    started = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": database},
        ResultConfiguration={"OutputLocation": f"s3://{bucket}/athena-results/"},
        WorkGroup="primary",
    )
    qid = started["QueryExecutionId"]
    while True:
        q = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]
        state = q["Status"]["State"]
        if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
            return q
        time.sleep(1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--bucket", required=True, help="your bucket with payments/ copied in"
    )
    ap.add_argument("--region", default="us-east-1")
    ap.add_argument(
        "--dir", default="athena/sql", help="folder of .sql files, relative to lab8/"
    )
    ap.add_argument("--only", nargs="*", help="file number prefixes to run, e.g. 09 14")
    args = ap.parse_args()

    session = boto3.Session(region_name=args.region)
    athena, s3 = session.client("athena"), session.client("s3")
    sql_dir = LAB8 / args.dir
    RESULTS = sql_dir.parent / "results"  # athena/results or cloud/results
    RESULTS.mkdir(exist_ok=True)
    stats = RESULTS / "stats.md"
    if not stats.exists():
        stats.write_text(
            "| query | state | run time, s | data scanned, MB | run at (UTC) |\n"
            "|---|---|---|---|---|\n"
        )

    files = sorted(sql_dir.glob("*.sql"))
    if args.only:
        files = [f for f in files if f.name.split("_")[0] in args.only]

    for f in files:
        sql = f.read_text().replace("${BUCKET}", args.bucket)
        # CREATE DATABASE must not run inside the database it creates.
        database = "default" if "create_database" in f.name else DATABASE
        q = run(athena, sql, args.bucket, database)
        state = q["Status"]["State"]
        st = q.get("Statistics", {})
        secs = st.get("EngineExecutionTimeInMillis", 0) / 1000
        mb = st.get("DataScannedInBytes", 0) / 1e6
        print(f"{f.name:35} {state:9} {secs:7.2f} s {mb:10.2f} MB")
        with stats.open("a") as out:
            now = dt.datetime.now(dt.UTC).strftime("%Y-%m-%d %H:%M")
            out.write(f"| {f.stem} | {state} | {secs:.2f} | {mb:.2f} | {now} |\n")

        if state != "SUCCEEDED":
            print("   ", q["Status"].get("StateChangeReason", ""), file=sys.stderr)
            return 1

        # SELECT queries leave a CSV in the output location: keep a copy next to the SQL.
        first = next(
            l for l in sql.splitlines() if l.strip() and not l.lstrip().startswith("--")
        )
        if q.get("StatementType") == "DML" and first.lstrip().upper().startswith(
            ("SELECT", "WITH")
        ):
            loc = q["ResultConfiguration"][
                "OutputLocation"
            ]  # s3://bucket/athena-results/<id>.csv
            key = loc.split("/", 3)[3]
            body = s3.get_object(Bucket=args.bucket, Key=key)["Body"].read()
            (RESULTS / f"{f.stem}.csv").write_bytes(body)
            preview = body.decode().splitlines()[:6]
            for line in preview:
                print("    " + line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
