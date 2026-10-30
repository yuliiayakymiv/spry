"""Part 4 on the AWS Free plan: SQS -> this Lambda -> S3 (archive) + SNS (alert).

Kinesis and Firehose are not available on the Free plan, so one Lambda does the work of both
consumers of the Kinesis stream in the lab diagram:
  - the Firehose part: every batch is written to S3 as one gzip JSON Lines file under
    stream/dt=<arrival date>/, which Athena reads (table lab8.payments_stream);
  - the real-time part: failure share per paymentMethod over the batch, SNS e-mail above 10 %.

The event source mapping collects messages for up to 60 s (MaximumBatchingWindowInSeconds) or
10 000 messages, so one invocation is about one minute of ARRIVAL time (processing time), like the
Kinesis Lambda's 60-second tumbling window. Duplicates are dropped within a batch only.

Environment: BUCKET, TOPIC_ARN, THRESHOLD (0.10), MIN_COUNT (10).
"""

import datetime as dt
import gzip
import json
import os

import boto3

s3 = boto3.client("s3")
sns = boto3.client("sns")
THRESHOLD = float(os.environ.get("THRESHOLD", "0.10"))
MIN_COUNT = int(os.environ.get("MIN_COUNT", "10"))


def handler(event, context):
    lines, seen, dups = [], set(), 0
    counts: dict[str, list[int]] = {}  # paymentMethod -> [finished, failed]
    for record in event.get("Records", []):
        for line in record["body"].splitlines():
            if not line.strip():
                continue
            ev = json.loads(line)
            key = f"{ev['invoiceId']}|{ev['status']}|{ev['modifiedDate']}"
            if key in seen:
                dups += 1
                continue
            seen.add(key)
            lines.append(line)
            if ev["status"] in ("success", "failure"):
                c = counts.setdefault(ev.get("paymentMethod") or "unknown", [0, 0])
                c[0] += 1
                c[1] += ev["status"] == "failure"
    if not lines:
        return {"batchItemFailures": []}

    # 1. Archive (what Firehose did): one object per batch, partitioned by arrival date.
    now = dt.datetime.now(dt.UTC)
    key = f"stream/dt={now:%Y-%m-%d}/{now:%H%M%S}-{context.aws_request_id}.jsonl.gz"
    body = gzip.compress(("\n".join(lines) + "\n").encode())
    s3.put_object(Bucket=os.environ["BUCKET"], Key=key, Body=body)

    # 2. Real-time metric + alert.
    shares = {m: (f / t if t else 0.0, f, t) for m, (t, f) in counts.items()}
    summary = "  ".join(
        f"{m} {f}/{t}={s:.0%}" for m, (s, f, t) in sorted(shares.items())
    )
    print(
        json.dumps(
            {
                "batch_at": now.isoformat(timespec="seconds"),
                "messages": len(event["Records"]),
                "events": len(lines),
                "duplicates": dups,
                "s3_key": key,
                "summary": summary,
            }
        )
    )

    alerts = [
        f"{m}: {s:.0%} ({f} of {t})"
        for m, (s, f, t) in sorted(shares.items())
        if s > THRESHOLD and t >= MIN_COUNT
    ]
    if alerts:
        sns.publish(
            TopicArn=os.environ["TOPIC_ARN"],
            Subject="Lab 8: payment failure share above threshold",
            Message=(
                f"Batch at {now:%Y-%m-%d %H:%M:%S} UTC (about one minute of arrivals)\n"
                f"Failure share above {THRESHOLD:.0%}:\n  "
                + "\n  ".join(alerts)
                + f"\n\nAll methods: {summary}"
            ),
        )
        print(json.dumps({"alert": alerts}))
    return {"batchItemFailures": []}
