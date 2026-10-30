"""Part 4: the real-time road in the cloud. Kinesis -> this Lambda -> SNS e-mail.

The event source mapping runs it with a 60-second TUMBLING WINDOW: Lambda passes `state` from
one invocation to the next inside a window and sets `isFinalInvokeForWindow` on the last one.
So the window is one minute of ARRIVAL time in Kinesis (processing time), not of modifiedDate
(event time) as in the local consumer: a late event is simply counted in the minute it arrived.

Environment: TOPIC_ARN, THRESHOLD (0.10), MIN_COUNT (10).
"""

import base64
import json
import os

import boto3

sns = boto3.client("sns")
THRESHOLD = float(os.environ.get("THRESHOLD", "0.10"))
MIN_COUNT = int(os.environ.get("MIN_COUNT", "10"))


def handler(event, context):
    state = event.get("state") or {}
    counts = state.get("counts", {})  # paymentMethod -> [finished, failed]
    seen = set(state.get("seen", []))  # dedup keys, only within this window
    dups = state.get("dups", 0)
    n = state.get("n", 0)

    for record in event.get("Records", []):
        data = base64.b64decode(record["kinesis"]["data"]).decode()
        for line in data.splitlines():
            if not line.strip():
                continue
            ev = json.loads(line)
            n += 1
            key = f"{ev['invoiceId']}|{ev['status']}|{ev['modifiedDate']}"
            if key in seen:
                dups += 1
                continue
            seen.add(key)
            if ev["status"] in ("success", "failure"):
                c = counts.setdefault(ev.get("paymentMethod") or "unknown", [0, 0])
                c[0] += 1
                c[1] += ev["status"] == "failure"

    if not event.get("isFinalInvokeForWindow"):
        # Not the end of the minute yet: hand the running totals to the next invocation.
        return {"state": {"counts": counts, "seen": sorted(seen), "dups": dups, "n": n}}

    window = event.get("window", {})
    shares = {m: (f / t if t else 0.0, f, t) for m, (t, f) in counts.items()}
    summary = "  ".join(
        f"{m} {f}/{t}={s:.0%}" for m, (s, f, t) in sorted(shares.items())
    )
    print(
        json.dumps(
            {
                "window": window,
                "events": n,
                "duplicates": dups,
                "summary": summary,
                "shard": event.get("shardId"),
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
                f"Window {window.get('start')} - {window.get('end')} (arrival time)\n"
                f"Failure share above {THRESHOLD:.0%}:\n  "
                + "\n  ".join(alerts)
                + f"\n\nAll methods: {summary}"
            ),
        )
        print(json.dumps({"alert": alerts}))
    return {}
