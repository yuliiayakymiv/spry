"""Part 4 in one go (~15 min): create the stream, send data, query it, delete the stream.

    python lab8/run_part4.py --bucket lab8-payments-<account> --email you@example.com

1. lab8/cloud/up.sh: Kinesis stream, Firehose -> S3, Lambda alert -> SNS e-mail;
2. producer: 10 000 normal events, then 6 000 with 30 % of payments failed (the alert);
3. waits for Firehose to flush, runs lab8/cloud/sql/*.sql in Athena -> lab8/cloud/results/;
4. saves the Lambda's log lines (one per window, plus alerts) -> lab8/data/part4/lambda-log.txt;
5. ALWAYS runs lab8/cloud/down.sh at the end, even after an error, so no shard keeps billing.
Summary with the time the stream existed and the cost estimate: lab8/data/part4/SUMMARY.txt.
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
            "Stream is up. Confirm the AWS Notifications e-mail now to receive the alert (60 s)."
        )
        time.sleep(60)

        t = time.time()
        run(
            py
            + [
                "lab8/producer.py",
                str(DATA),
                "--sink",
                "kinesis",
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
                "kinesis",
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
        log(f"16 000 events sent to Kinesis in {time.time() - t:.0f} s")

        log("waiting 150 s for Firehose (60 s buffer) and the last Lambda window...")
        time.sleep(150)
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
            logGroupName="/aws/lambda/lab8-failure-alert"
        ):
            lines += [
                e["message"].strip()
                for e in page["events"]
                if e["message"].startswith("{")
            ]
        (OUT / "lambda-log.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        alerts = [x for x in lines if '"alert"' in x]
        log(
            f"Lambda: {len(lines) - len(alerts)} windows logged, {len(alerts)} alerts sent to SNS"
        )
        for a in alerts[:3]:
            log(f"  {a}")
    finally:
        run([sh, "lab8/cloud/down.sh"], env, check=False)
        hours = (time.time() - created) / 3600
        log(
            f"The Kinesis stream existed {hours * 60:.0f} min = {hours:.2f} shard-hours "
            f"x $0.015 = ${hours * 0.015:.3f} (+ Firehose/Lambda/S3/Athena: cents)"
        )
        (OUT / "SUMMARY.txt").write_text("\n".join(summary) + "\n", encoding="utf-8")
    print("\nDone. Results: lab8/cloud/results/, lab8/data/part4/")


if __name__ == "__main__":
    main()
