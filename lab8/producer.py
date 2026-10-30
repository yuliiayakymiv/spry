"""Replay one day of payment events into a stream, in the order they reached us.

Part 3 sends to the local Redpanda topic, Part 4 to an SQS queue (or a Kinesis stream on the
AWS Paid plan): the replay logic
is the same, only the sink differs.

    # one day of the dataset (the bucket is public)
    aws s3 cp s3://ucu-ooad-lab8-payments/payments/dt=2026-10-01/events.jsonl lab8/data/ --no-sign-request

    python lab8/producer.py lab8/data/events.jsonl                         # -> Redpanda, 20 payments/s
    python lab8/producer.py lab8/data/events.jsonl --fail-share 0.3        # experiment 3
    python lab8/producer.py lab8/data/events.jsonl --sink sqs --stream lab8-payments
    python lab8/producer.py lab8/data/events.jsonl --sink kinesis --stream lab8-payments
    python lab8/producer.py lab8/data/events.jsonl --sink stdout --max-events 5   # dry run

Order: events are sorted by receivedAt (processing time), not modifiedDate (event time), so an
event that was late in production is also late here: it arrives after newer events.
Key: invoiceId, so every event of one payment goes to the same partition / shard, in order.
"""

import argparse
import hashlib
import json
import sys
import time


def load(path: str, start: str | None) -> list[tuple[str, dict, str]]:
    """Read JSON Lines -> [(receivedAt, parsed event, original line)], sorted by receivedAt."""
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            ev = json.loads(line)
            rows.append((ev["receivedAt"], ev, line))
    # ISO 8601 strings in one format and one zone ("...Z") sort correctly as text.
    rows.sort(key=lambda r: r[0])
    if start:  # e.g. "08:00" -> skip the quiet night and start at a busy hour
        rows = [r for r in rows if r[0][11:16] >= start]
    return rows


def injected(invoice_id: str, share: float) -> bool:
    """Pick the same payments every run: a stable hash of invoiceId, not random()."""
    h = int(hashlib.sha1(invoice_id.encode()).hexdigest()[:8], 16)
    return h / 0xFFFFFFFF < share


def fail(ev: dict) -> str:
    """Experiment 3: turn a successful payment into a failed one, as the bank would send it."""
    ev = dict(
        ev,
        status="failure",
        finalAmount=0,
        failureReason="Injected failure (experiment)",
    )
    return json.dumps(ev, separators=(",", ":"))


class RedpandaSink:
    def __init__(self, brokers: str, topic: str):
        from confluent_kafka import Producer

        # acks=all + idempotence: the broker confirms each write and never stores one twice.
        self.p = Producer(
            {
                "bootstrap.servers": brokers,
                "acks": "all",
                "enable.idempotence": True,
                "linger.ms": 20,
            }
        )
        self.topic = topic

    def send(self, key: str, value: str) -> None:
        while True:
            try:
                self.p.produce(self.topic, key=key, value=value)
                break
            except BufferError:  # local queue full: let it drain, then retry
                self.p.poll(0.1)
        self.p.poll(0)

    def close(self) -> None:
        self.p.flush(30)


class KinesisSink:
    """Batches into PutRecords (up to 500 records) and resends what Kinesis throttled."""

    def __init__(self, stream: str, region: str):
        import boto3

        self.k = boto3.client("kinesis", region_name=region)
        self.stream = stream
        self.batch: list[dict] = []
        self.last_flush = time.monotonic()
        self.throttled = 0

    def send(self, key: str, value: str) -> None:
        self.batch.append({"Data": (value + "\n").encode(), "PartitionKey": key})
        if len(self.batch) >= 500 or time.monotonic() - self.last_flush > 0.5:
            self.flush()

    def flush(self) -> None:
        records, self.batch, self.last_flush = self.batch, [], time.monotonic()
        while records:
            resp = self.k.put_records(StreamName=self.stream, Records=records)
            if resp["FailedRecordCount"] == 0:
                return
            # Keep only the records that failed (ProvisionedThroughputExceeded) and retry them.
            records = [
                r for r, res in zip(records, resp["Records"]) if "ErrorCode" in res
            ]
            self.throttled += len(records)
            time.sleep(0.2)

    def close(self) -> None:
        self.flush()
        if self.throttled:
            print(
                f"kinesis: {self.throttled} records were throttled and re-sent",
                file=sys.stderr,
            )


class SqsSink:
    """SendMessageBatch, 10 messages per call. A standard queue has no partitions and no key:
    SQS does not keep the order of one payment's events, unlike a Kafka partition or a shard."""

    def __init__(self, queue: str, region: str):
        import boto3

        self.q = boto3.client("sqs", region_name=region)
        self.url = self.q.get_queue_url(QueueName=queue)["QueueUrl"]
        self.batch: list[dict] = []

    def send(self, key: str, value: str) -> None:
        self.batch.append({"Id": str(len(self.batch)), "MessageBody": value})
        if len(self.batch) == 10:
            self.flush()

    def flush(self) -> None:
        entries, self.batch = self.batch, []
        while entries:
            resp = self.q.send_message_batch(QueueUrl=self.url, Entries=entries)
            failed = {f["Id"] for f in resp.get("Failed", [])}
            entries = [e for e in entries if e["Id"] in failed]
            if entries:
                time.sleep(0.2)

    def close(self) -> None:
        if self.batch:
            self.flush()


class StdoutSink:
    def send(self, key: str, value: str) -> None:
        print(key, value)

    def close(self) -> None:
        pass


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("file", help="one day of events, JSON Lines (events.jsonl)")
    ap.add_argument(
        "--sink", choices=["redpanda", "sqs", "kinesis", "stdout"], default="redpanda"
    )
    ap.add_argument("--brokers", default="localhost:19092")
    ap.add_argument("--topic", default="payments")
    ap.add_argument(
        "--stream", default="lab8-payments", help="SQS queue or Kinesis stream name"
    )
    ap.add_argument("--region", default="us-east-1")
    ap.add_argument(
        "--rate", type=float, default=20, help="payments per second (default 20)"
    )
    ap.add_argument(
        "--fail-share",
        type=float,
        default=0.0,
        help="turn this share of payments into failures",
    )
    ap.add_argument("--start", help="start at this receivedAt time of day, HH:MM (UTC)")
    ap.add_argument("--max-events", type=int, help="stop after this many events")
    args = ap.parse_args()

    rows = load(args.file, args.start)
    if args.max_events:
        rows = rows[: args.max_events]
    payments = len({ev["invoiceId"] for _, ev, _ in rows})
    # 20 payments/s with ~3 events per payment = ~60 events/s.
    events_per_s = args.rate * len(rows) / max(payments, 1)
    print(
        f"{len(rows)} events of {payments} payments -> {args.sink}, "
        f"{args.rate:g} payments/s = {events_per_s:.1f} events/s, "
        f"~{len(rows) / events_per_s / 60:.0f} min",
        file=sys.stderr,
    )

    sink = {
        "redpanda": lambda: RedpandaSink(args.brokers, args.topic),
        "sqs": lambda: SqsSink(args.stream, args.region),
        "kinesis": lambda: KinesisSink(args.stream, args.region),
        "stdout": StdoutSink,
    }[args.sink]()

    started = time.monotonic()
    changed = 0
    i = -1
    last_report = started
    try:
        for i, (_, ev, line) in enumerate(rows):
            # Fixed schedule: event i leaves at i / events_per_s seconds after the start.
            wait = started + i / events_per_s - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            if (
                args.fail_share
                and ev["status"] == "success"
                and injected(ev["invoiceId"], args.fail_share)
            ):
                line = fail(ev)
                changed += 1
            sink.send(ev["invoiceId"], line)

            now = time.monotonic()
            if now - last_report >= 10:
                last_report = now
                print(
                    f"  sent {i + 1}/{len(rows)}  receivedAt={ev['receivedAt']}",
                    file=sys.stderr,
                )
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        i -= 1
    finally:
        sink.close()
    print(
        f"done: {i + 1} events sent in {time.monotonic() - started:.0f} s"
        + (f", {changed} successes turned into failures" if args.fail_share else ""),
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
