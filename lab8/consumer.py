"""Failure share per payment method in one-minute windows of event time, with an alert.

    python lab8/consumer.py                              # read the `payments` topic in Redpanda
    python lab8/consumer.py --state lab8/data/state.json # experiment 1: stop/start without losing counts
    python lab8/consumer.py --group exp4 --lateness 0 --out lab8/data/lateness0.csv   # experiment 4
    python lab8/consumer.py --file lab8/data/events.jsonl                # same logic, no broker

What it does with every message, in order:
  1. drop it if it is an exact duplicate (same invoiceId + status + modifiedDate seen before);
  2. put it in the one-minute window of its EVENT time (modifiedDate), not of its arrival;
  3. move the watermark: the newest event time seen in EACH partition, and the overall watermark
     is the minimum of those (as in Flink). Partitions are read in batches, so after a pause one
     partition can run minutes ahead of another; taking the max would wrongly reject the slower
     partitions' events as late;
  4. close every window whose end + allowed lateness (2 min) is behind the watermark: print
     failure share per paymentMethod and an ALERT if it is above 10 %;
  5. an event whose window is already closed is LATE: counted and rejected.

Failure share = failure / (success + failure) among final statuses in the window.
"""

import argparse
import csv
import json
import signal
import sys
import time
from collections import defaultdict
from contextlib import nullcontext
from datetime import UTC, datetime

FINAL = ("success", "failure")


def epoch(iso: str) -> int:
    return int(datetime.fromisoformat(iso).timestamp())


def hhmm(ts: int) -> str:
    return datetime.fromtimestamp(ts, UTC).strftime("%m-%d %H:%M")


class FailureRateWindows:
    def __init__(
        self, window_s=60, lateness_s=120, threshold=0.10, min_count=10, out=None
    ):
        self.window_s, self.lateness_s = window_s, lateness_s
        self.threshold, self.min_count = threshold, min_count
        # window start -> paymentMethod -> [finished, failed]
        self.open: dict[int, dict[str, list[int]]] = defaultdict(
            lambda: defaultdict(lambda: [0, 0])
        )
        self.watermark = 0
        self.part_wm: dict[int, int] = {}  # partition -> newest event time seen in it
        # The dedup memory. It only grows: in production it lives in Redis / Flink state with a TTL
        # (a duplicate cannot arrive days later, so a key can be forgotten after, say, 1 hour).
        self.seen: set[str] = set()
        self.stats = {
            "received": 0,
            "duplicates": 0,
            "late": 0,
            "late_final": 0,
            "windows": 0,
            "alerts": 0,
        }
        self.out = out

    # ---- one event ----
    def process(self, ev: dict, partition: int = 0) -> None:
        self.stats["received"] += 1
        key = f"{ev['invoiceId']}|{ev['status']}|{ev['modifiedDate']}"
        if key in self.seen:
            self.stats["duplicates"] += 1
            return
        self.seen.add(key)

        t = epoch(ev["modifiedDate"])
        start = t - t % self.window_s
        if start + self.window_s + self.lateness_s <= self.watermark:
            # Its window was already printed: too late to change it.
            self.stats["late"] += 1
            if ev["status"] in FINAL:
                self.stats["late_final"] += 1
            return

        if ev["status"] in FINAL:
            cell = self.open[start][ev.get("paymentMethod") or "unknown"]
            cell[0] += 1
            cell[1] += ev["status"] == "failure"

        if t > self.part_wm.get(partition, 0):
            self.part_wm[partition] = t
            wm = min(self.part_wm.values())
            if wm > self.watermark:
                self.watermark = wm
                self.close_ready()

    def forget_partitions(self, partitions: list[int]) -> None:
        """Partitions handed to another consumer no longer hold our watermark back."""
        for p in partitions:
            self.part_wm.pop(p, None)

    # ---- closing windows ----
    def close_ready(self) -> None:
        for start in sorted(self.open):
            if start + self.window_s + self.lateness_s > self.watermark:
                break
            self.emit(start, self.open.pop(start))

    def flush(self, why: str) -> None:
        """Close everything still open (end of stream, shutdown without a state file)."""
        for start in sorted(self.open):
            self.emit(start, self.open.pop(start), note=why)

    def emit(self, start: int, methods: dict, note: str = "") -> None:
        self.stats["windows"] += 1
        parts, alerts = [], []
        for m, (n, f) in sorted(methods.items()):
            share = f / n if n else 0.0
            parts.append(f"{m} {f}/{n}={share:.0%}")
            if self.out:
                self.out.writerow([hhmm(start), m, n, f, f"{share:.4f}"])
            if share > self.threshold and n >= self.min_count:
                alerts.append(f"{m} {share:.0%} ({f} of {n})")
        print(
            f"[{hhmm(start)}] " + "  ".join(parts) + (f"  ({note})" if note else ""),
            flush=True,
        )
        for a in alerts:
            self.stats["alerts"] += 1
            print(
                f"  ALERT {hhmm(start)}: failure share {a} > {self.threshold:.0%}",
                flush=True,
            )

    # ---- state for experiment 1 ----
    def dump(self) -> dict:
        return {
            "watermark": self.watermark,
            "part_wm": self.part_wm,
            "seen": sorted(self.seen),
            "stats": self.stats,
            "open": {
                str(s): {m: c for m, c in ms.items()} for s, ms in self.open.items()
            },
        }

    def load(self, st: dict) -> None:
        self.watermark, self.seen, self.stats = (
            st["watermark"],
            set(st["seen"]),
            st["stats"],
        )
        self.part_wm = {int(k): v for k, v in st.get("part_wm", {}).items()}
        for s, ms in st["open"].items():
            for m, c in ms.items():
                self.open[int(s)][m] = c

    def summary(self) -> str:
        s = self.stats
        return (
            f"received {s['received']}, duplicates dropped {s['duplicates']}, "
            f"late rejected {s['late']} (final statuses among them {s['late_final']}), "
            f"windows {s['windows']}, alerts {s['alerts']}, dedup set size {len(self.seen)}"
        )


def from_file(path: str, agg: FailureRateWindows) -> None:
    """The same stream without a broker: the file in arrival (receivedAt) order."""
    with open(path, encoding="utf-8") as f:
        events = [json.loads(line) for line in f if line.strip()]
    events.sort(key=lambda e: e["receivedAt"])
    for ev in events:
        agg.process(ev)
    agg.flush("end of file")


def from_redpanda(args, agg: FailureRateWindows) -> None:
    from confluent_kafka import Consumer, KafkaException

    c = Consumer(
        {
            "bootstrap.servers": args.brokers,
            "group.id": args.group,
            "auto.offset.reset": "earliest",  # a new group starts from the beginning of the log
            "enable.auto.commit": False,  # we commit ourselves, together with the state
        }
    )

    def on_assign(consumer, partitions):
        print(f"# assigned partitions {[p.partition for p in partitions]}", flush=True)

    def on_revoke(consumer, partitions):
        # Hand the partitions over with our position committed, so the next owner does not
        # re-read what we already counted.
        print(f"# revoked partitions {[p.partition for p in partitions]}", flush=True)
        agg.forget_partitions([p.partition for p in partitions])
        try:
            consumer.commit(asynchronous=False)
        except KafkaException as e:  # e.g. nothing consumed yet
            print(f"# commit skipped: {e}", flush=True)

    c.subscribe([args.topic], on_assign=on_assign, on_revoke=on_revoke)

    stop = False

    def handle(*_):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, handle)
    signal.signal(signal.SIGTERM, handle)
    if hasattr(
        signal, "SIGBREAK"
    ):  # Windows: Ctrl+Break, what run_part3.py sends to stop us
        signal.signal(signal.SIGBREAK, handle)

    last_msg, last_report = time.monotonic(), time.monotonic()
    while not stop:
        msg = c.poll(0.5)
        now = time.monotonic()
        if now - last_report >= 10:
            last_report = now
            print(
                f"# {agg.summary()}, watermark {hhmm(agg.watermark) if agg.watermark else '-'}",
                flush=True,
            )
        if msg is None:
            if agg.open and now - last_msg > args.idle:
                agg.flush(f"no events for {args.idle:g} s")
            continue
        if msg.error():
            print(f"# {msg.error()}", file=sys.stderr)
            continue
        last_msg = now
        agg.process(json.loads(msg.value()), msg.partition())

    # Graceful stop (Ctrl+C): remember where we are. With --state the open windows and the dedup
    # set are saved too, so a restart continues exactly; without it they are printed as partial.
    if args.state:
        with open(args.state, "w") as f:
            json.dump(agg.dump(), f)
        print(f"# state saved to {args.state} ({len(agg.open)} open windows)")
    else:
        agg.flush("partial: consumer stopped")
    try:
        c.commit(asynchronous=False)
    except KafkaException as e:
        print(f"# commit skipped: {e}", flush=True)
    c.close()


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--brokers", default="localhost:19092")
    ap.add_argument("--topic", default="payments")
    ap.add_argument("--group", default="lab8-failure-rate", help="consumer group id")
    ap.add_argument(
        "--lateness",
        type=int,
        default=120,
        help="seconds to wait for late events (default 120)",
    )
    ap.add_argument("--threshold", type=float, default=0.10)
    ap.add_argument(
        "--min-count",
        type=int,
        default=10,
        help="no alert for a method with fewer final payments in the window (noise)",
    )
    ap.add_argument(
        "--idle",
        type=float,
        default=15,
        help="close open windows after this many idle seconds",
    )
    ap.add_argument(
        "--state", help="JSON file: load on start, save on Ctrl+C (experiment 1)"
    )
    ap.add_argument(
        "--out", help="write every closed window to this CSV (to compare runs)"
    )
    ap.add_argument("--file", help="read a JSON Lines file instead of Redpanda")
    args = ap.parse_args()

    with open(args.out, "w", newline="") if args.out else nullcontext() as out_f:
        writer = csv.writer(out_f) if out_f else None
        if writer:
            writer.writerow(
                ["window_utc", "payment_method", "finished", "failed", "failure_share"]
            )

        agg = FailureRateWindows(
            lateness_s=args.lateness,
            threshold=args.threshold,
            min_count=args.min_count,
            out=writer,
        )
        if args.state and not args.file:
            try:
                with open(args.state) as f:
                    agg.load(json.load(f))
                print(f"# state loaded from {args.state}: {agg.summary()}")
            except FileNotFoundError:
                pass

        print(
            f"# windows 60 s of event time, allowed lateness {args.lateness} s, "
            f"alert above {args.threshold:.0%} (min {args.min_count} final payments)",
            flush=True,
        )
        if args.file:
            from_file(args.file, agg)
        else:
            from_redpanda(args, agg)
        print(f"# TOTAL: {agg.summary()}", flush=True)


if __name__ == "__main__":
    main()
