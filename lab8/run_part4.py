"""Part 4 in one go (~10 min): create the pipeline, send data, query it, delete the pipeline.

    python lab8/run_part4.py --bucket lab8-payments-<account> --email you@example.com

1. lab8/cloud/up.sh: SQS queue -> Lambda -> S3 stream/ + SNS e-mail (AWS Free plan version;
   lab8/cloud/up-kinesis.sh is the Kinesis + Firehose version for the Paid plan);
2. producer: 10 000 normal events, then 6 000 with 30 % of payments failed (the alert);
3. waits for Firehose to flush, runs lab8/cloud/sql/*.sql in Athena -> lab8/cloud/results/;
4. saves the Lambda's log lines (one per window, plus alerts) -> lab8/data/part4/lambda-log.txt;
5. ALWAYS runs lab8/cloud/down.sh at the end, even after an error.
Summary with how long the pipeline existed and what it used: lab8/data/part4/SUMMARY.txt.
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import time

import boto3

LAB8 = pathlib.Path(__file__).resolve().parent
OUT = LAB8 / "data" / "part4"
DATA = LAB8 / "data" / "events.jsonl"
REGION = "us-east-1"
summary: list[str] = []


def log(msg: str) -> None:
    print(msg, flush=True)
    summary.append(msg)


def bash() -> str:
    for candidate in (
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
    ):
        if os.path.exists(candidate):
            return candidate
    found = shutil.which("bash")
    if not found:
        sys.exit("bash not found: install Git for Windows")
    return found


def run(args: list[str], env: dict, check: bool = True) -> None:
    print("$ " + " ".join(args), flush=True)
    subprocess.run(args, env=env, check=check)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bucket", required=True)
    ap.add_argument("--email", required=True)
    args = ap.parse_args()
    os.chdir(LAB8.parent)
    OUT.mkdir(parents=True, exist_ok=True)
    if not DATA.exists():
        sys.exit(f"missing {DATA}")

    env = dict(
        os.environ,
        BUCKET=args.bucket,
        EMAIL=args.email,
        PYTHON=sys.executable,
        REGION=REGION,
    )
    py = [sys.executable, "-u"]
    sh = bash()
    created = time.time()
    try:
        run([sh, "lab8/cloud/up.sh"], env)
        log(
            "Pipeline is up. Confirm the AWS Notifications e-mail now to receive the alert (60 s)."
        )
        time.sleep(60)

        t = time.time()
        run(
            py
            + [
                "lab8/producer.py",
                str(DATA),
                "--sink",
                "sqs",
                "--start",
                "08:00",
                "--max-events",
                "10000",
                "--rate",
                "60",
            ],
            env,
        )
        run(
            py
            + [
                "lab8/producer.py",
                str(DATA),
                "--sink",
                "sqs",
                "--start",
                "12:00",
                "--max-events",
                "6000",
                "--rate",
                "60",
                "--fail-share",
                "0.3",
            ],
            env,
        )
        log(f"16 000 events sent to SQS in {time.time() - t:.0f} s")

        log("waiting 120 s for the last Lambda batch (60 s batching window)...")
        time.sleep(120)
        run(
            py
            + [
                "lab8/athena/run_athena.py",
                "--bucket",
                args.bucket,
                "--dir",
                "cloud/sql",
            ],
            env,
        )

        logs = boto3.client("logs", region_name=REGION)
        lines = []
        for page in logs.get_paginator("filter_log_events").paginate(
            logGroupName="/aws/lambda/lab8-stream-processor"
        ):
            lines += [
                e["message"].strip()
                for e in page["events"]
                if e["message"].startswith("{")
            ]
        (OUT / "lambda-log.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        alerts = [x for x in lines if '"alert"' in x]
        log(
            f"Lambda: {len(lines) - len(alerts)} batches written to S3, {len(alerts)} alerts sent to SNS"
        )
        for a in alerts[:3]:
            log(f"  {a}")
    finally:
        run([sh, "lab8/cloud/down.sh"], env, check=False)
        minutes = (time.time() - created) / 60
        log(
            f"The pipeline existed {minutes:.0f} min. SQS requests, Lambda invocations, SNS e-mails "
            "and S3/Athena use are all inside the Free plan: cost $0.00 (Kinesis would have been "
            f"{minutes / 60:.2f} shard-hours x $0.015 + Firehose per GB)"
        )
        (OUT / "SUMMARY.txt").write_text("\n".join(summary) + "\n", encoding="utf-8")
    print("\nDone. Results: lab8/cloud/results/, lab8/data/part4/")


if __name__ == "__main__":
    main()
