"""Part 3, all four experiments in one go (~20 min). Needs Docker Desktop running.

    python lab8/run_part3.py

Every consumer and producer output lands in lab8/data/part3/, and a summary of what to put in
the report in lab8/data/part3/SUMMARY.txt. Instead of screenshots of Redpanda Console, the
script prints the same facts as text: consumer-group lag while the consumer is stopped
(experiment 1) and which member owns which partition (experiment 2).
"""

import os
import pathlib
import re
import signal
import subprocess
import sys
import time

LAB8 = pathlib.Path(__file__).resolve().parent
OUT = LAB8 / "data" / "part3"
DATA = LAB8 / "data" / "events.jsonl"
COMPOSE = ["docker", "compose", "-f", str(LAB8 / "docker-compose.yml")]
BROKERS = "localhost:19092"
PY = [sys.executable, "-u"]
WINDOWS = os.name == "nt"
summary: list[str] = []


def log(msg: str) -> None:
    print(msg, flush=True)
    summary.append(msg)


def start(args: list[str], name: str) -> subprocess.Popen:
    """Run a script in the background, stdout + stderr into OUT/name.txt."""
    f = open(OUT / f"{name}.txt", "w", encoding="utf-8")  # noqa: SIM115 - closed in stop()
    flags = subprocess.CREATE_NEW_PROCESS_GROUP if WINDOWS else 0
    p = subprocess.Popen(
        PY + args, stdout=f, stderr=subprocess.STDOUT, creationflags=flags
    )
    p.logfile = f  # type: ignore[attr-defined]
    return p


def stop(p: subprocess.Popen) -> None:
    """Graceful stop, like Ctrl+C: the consumer saves state and commits offsets."""
    if p.poll() is None:
        p.send_signal(signal.CTRL_BREAK_EVENT if WINDOWS else signal.SIGINT)
        try:
            p.wait(30)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
    p.logfile.close()  # type: ignore[attr-defined]


def text(name: str) -> str:
    return (OUT / f"{name}.txt").read_text(encoding="utf-8")


def last(name: str, pattern: str) -> str:
    lines = [line for line in text(name).splitlines() if re.search(pattern, line)]
    return lines[-1].strip() if lines else "(not found)"


def reset_topic() -> None:
    """Fresh broker and an empty `payments` topic with 3 partitions."""
    from confluent_kafka.admin import AdminClient

    subprocess.run(COMPOSE + ["down", "-v"], check=True, capture_output=True)
    subprocess.run(COMPOSE + ["up", "-d"], check=True)
    admin = AdminClient({"bootstrap.servers": BROKERS})
    for _ in range(90):
        try:
            md = admin.list_topics(timeout=3)
            if "payments" in md.topics and len(md.topics["payments"].partitions) == 3:
                return
        except Exception as e:  # noqa: BLE001 - broker still starting
            print(f"  waiting for Redpanda ({type(e).__name__})", flush=True)
        time.sleep(2)
    sys.exit("Redpanda did not come up with the payments topic: docker compose logs")


def lag(group: str) -> tuple[int, list[int]]:
    """Messages in the topic that the group has not committed yet, per partition."""
    from confluent_kafka import Consumer, TopicPartition

    c = Consumer(
        {"bootstrap.servers": BROKERS, "group.id": group, "enable.auto.commit": False}
    )
    try:
        parts = sorted(
            c.list_topics("payments", timeout=10).topics["payments"].partitions
        )
        per = []
        for tp in c.committed(
            [TopicPartition("payments", p) for p in parts], timeout=10
        ):
            low, high = c.get_watermark_offsets(tp, timeout=10)
            per.append(high - (tp.offset if tp.offset >= 0 else low))
        return sum(per), per
    finally:
        c.close()


def members(group: str) -> list[str]:
    from confluent_kafka.admin import AdminClient

    admin = AdminClient({"bootstrap.servers": BROKERS})
    desc = admin.describe_consumer_groups([group])[group].result(timeout=10)
    return [
        f"{m.client_id} ({m.host}): partitions "
        f"{sorted(tp.partition for tp in m.assignment.topic_partitions)}"
        for m in desc.members
    ]


def produce(name: str, *extra: str) -> subprocess.Popen:
    return start(
        [
            "lab8/producer.py",
            str(DATA),
            "--start",
            "08:00",
            "--max-events",
            "15000",
            *extra,
        ],
        name,
    )


def sent(name: str) -> str:
    m = re.search(r"done: (\d+) events", text(name))
    return m.group(1) if m else "?"


def wait_idle(name: str, quiet: float = 25, limit: float = 900) -> None:
    """Wait until the consumer has caught up: its `received N` count stops growing."""
    t0, seen, since = time.time(), None, time.time()
    while time.time() - t0 < limit:
        time.sleep(3)
        counts = re.findall(r"received (\d+)", text(name))
        n = counts[-1] if counts else None
        if n != seen:
            seen, since = n, time.time()
        elif n and n != "0" and time.time() - since > quiet:
            return


def experiment1() -> None:
    log("\n=== Experiment 1: stop the consumer for a minute, start it again ===")
    reset_topic()
    state = OUT / "state.json"
    state.unlink(missing_ok=True)
    cons = ["lab8/consumer.py", "--state", str(state)]
    c = start(cons, "exp1a-consumer")
    p = produce("exp1-producer")
    time.sleep(90)
    stop(c)
    log(f"consumer stopped after 90 s: {last('exp1a-consumer', 'state saved')}")
    for i in range(4):
        time.sleep(15)
        total, per = lag("lab8-failure-rate")
        log(
            f"  +{15 * (i + 1)} s, consumer down: group lag {total} (per partition {per})"
        )
    c = start(cons, "exp1b-consumer")
    p.wait()
    wait_idle("exp1b-consumer")
    stop(c)
    total, per = lag("lab8-failure-rate")
    log(f"after restart and catching up: group lag {total} (per partition {per})")
    log(f"producer: {sent('exp1-producer')} events sent")
    log(f"consumer: {last('exp1b-consumer', 'TOTAL')}")


def experiment2() -> None:
    log("\n=== Experiment 2: two consumers in one group ===")
    reset_topic()  # both consumers must be in the group before data arrives
    a = start(["lab8/consumer.py", "--group", "exp2"], "exp2a-consumer")
    b = start(["lab8/consumer.py", "--group", "exp2"], "exp2b-consumer")
    time.sleep(15)
    p = start(
        [
            "lab8/producer.py",
            str(DATA),
            "--start",
            "08:00",
            "--max-events",
            "6000",
            "--rate",
            "60",
        ],
        "exp2-producer",
    )
    time.sleep(30)
    for m in members("exp2"):
        log(f"  member {m}")
    log(f"consumer A: {last('exp2a-consumer', 'assigned partitions')}")
    log(f"consumer B: {last('exp2b-consumer', 'assigned partitions')}")
    stop(b)
    time.sleep(10)
    log(f"after B stopped, consumer A: {last('exp2a-consumer', 'assigned partitions')}")
    p.wait()
    wait_idle("exp2a-consumer")
    stop(a)
    log(f"producer: {sent('exp2-producer')} events sent")
    log(f"A: {last('exp2a-consumer', 'TOTAL')}")
    log(f"B (stopped after 30 s): {last('exp2b-consumer', 'TOTAL')}")


def experiment3() -> None:
    log("\n=== Experiment 3: producer fails 30 % of payments ===")
    reset_topic()
    c = start(["lab8/consumer.py", "--group", "exp3"], "exp3-consumer")
    p = produce("exp3-producer", "--fail-share", "0.3", "--rate", "60")
    p.wait()
    wait_idle("exp3-consumer")
    stop(c)
    out = text("exp3-consumer")
    log(f"producer: {last('exp3-producer', 'done:')}")
    log(
        f"ALERT lines: {out.count('ALERT')}; first one: {last('exp3-consumer', 'ALERT') if 'ALERT' in out else '-'}"
    )
    log(f"consumer: {last('exp3-consumer', 'TOTAL')}")


def experiment4() -> None:
    log("\n=== Experiment 4: allowed lateness 120 s vs 0 s ===")
    reset_topic()
    p = produce("exp4-producer", "--rate", "200")
    p.wait()
    for lateness in ("120", "0"):
        name = f"exp4-lateness{lateness}"
        c = start(
            [
                "lab8/consumer.py",
                "--group",
                f"exp4-{lateness}",
                "--lateness",
                lateness,
                "--out",
                str(OUT / f"lateness{lateness}.csv"),
            ],
            name,
        )
        wait_idle(name)
        stop(c)
        log(f"lateness {lateness:>3} s: {last(name, 'TOTAL')}")
    cmp = subprocess.run(
        PY
        + [
            "lab8/compare_windows.py",
            str(OUT / "lateness120.csv"),
            str(OUT / "lateness0.csv"),
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    (OUT / "exp4-compare.txt").write_text(cmp, encoding="utf-8")
    log(cmp)


def main() -> None:
    os.chdir(LAB8.parent)
    OUT.mkdir(parents=True, exist_ok=True)
    if not DATA.exists():
        sys.exit(
            f"missing {DATA}: aws s3 cp s3://ucu-ooad-lab8-payments/payments/dt=2026-10-01/events.jsonl "
            "lab8/data/ --no-sign-request"
        )
    # python lab8/run_part3.py 4   -> only experiment 4 (any subset of 1 2 3 4)
    only = sys.argv[1:] or ["1", "2", "3", "4"]
    t0 = time.time()
    try:
        for n, exp in (
            ("1", experiment1),
            ("2", experiment2),
            ("3", experiment3),
            ("4", experiment4),
        ):
            if n in only:
                exp()
    finally:
        name = "SUMMARY.txt" if len(only) == 4 else f"SUMMARY-exp{''.join(only)}.txt"
        (OUT / name).write_text("\n".join(summary) + "\n", encoding="utf-8")
        subprocess.run(COMPOSE + ["down"], capture_output=True, check=False)
    print(f"\nDone in {(time.time() - t0) / 60:.0f} min. Everything is in {OUT}")


if __name__ == "__main__":
    main()
