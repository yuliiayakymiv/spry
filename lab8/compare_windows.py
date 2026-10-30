"""Experiment 4: what did waiting (or not waiting) for late events change in the window numbers?

    python lab8/compare_windows.py lab8/data/lateness120.csv lab8/data/lateness0.csv

Both files come from `consumer.py --out ...` over the same topic (two different --group ids).
"""

import csv
import sys


def read(path: str) -> dict[tuple[str, str], tuple[int, int]]:
    with open(path, newline="") as f:
        return {
            (r["window_utc"], r["payment_method"]): (
                int(r["finished"]),
                int(r["failed"]),
            )
            for r in csv.DictReader(f)
        }


def main(a_path: str, b_path: str) -> None:
    a, b = read(a_path), read(b_path)
    keys = sorted(a.keys() | b.keys())
    changed = [k for k in keys if a.get(k, (0, 0)) != b.get(k, (0, 0))]
    lost_fin = sum(a.get(k, (0, 0))[0] - b.get(k, (0, 0))[0] for k in keys)
    lost_fail = sum(a.get(k, (0, 0))[1] - b.get(k, (0, 0))[1] for k in keys)
    windows = {k[0] for k in keys}
    changed_windows = {k[0] for k in changed}
    print(f"{a_path}: {sum(v[0] for v in a.values())} final payments counted")
    print(f"{b_path}: {sum(v[0] for v in b.values())} final payments counted")
    print(
        f"difference: {lost_fin} payments ({lost_fail} of them failures) missing in the second run"
    )
    print(
        f"windows that changed: {len(changed_windows)} of {len(windows)}; "
        f"(window, method) cells that changed: {len(changed)} of {len(keys)}"
    )
    biggest = sorted(changed, key=lambda k: -abs(_share(a.get(k)) - _share(b.get(k))))[
        :10
    ]
    if biggest:
        print("\nlargest changes in failure share:")
        print(f"{'window':12} {'method':12} {'first':>14} {'second':>14}")
        for k in biggest:
            print(f"{k[0]:12} {k[1]:12} {_fmt(a.get(k)):>14} {_fmt(b.get(k)):>14}")


def _share(v):
    return v[1] / v[0] if v and v[0] else 0.0


def _fmt(v):
    return f"{v[1]}/{v[0]}={_share(v):.0%}" if v else "-"


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
