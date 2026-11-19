"""The same business results in app/ and with nfltr.

compare.py <evidence dir>: every agent's outcome, progress count and output
of the 5-step command are equal on (b) in app/ and on (a) mapping, (a) dial
and (b) with nfltr; every deadline run ends in the same status per agent; the
retry after an agent restart ends with the same result. Exit 1 otherwise.
"""
import json
import sys

t = sys.argv[1]


def outcomes(name):
    return [json.loads(l) for l in open(f"{t}/{name}.out") if l.startswith("{")]


def key(o, fields):
    return tuple(o[f] for f in fields)


full = ("agent", "status", "progress", "output")
checks = [  # (what, fields, runs: the first is the reference)
    ("5-step command", full, ["app-b-session", "a-mapping", "a-dial", "b-session"]),
    ("1 s deadline", ("agent", "status"), ["app-b-deadline", "a-deadline", "b-deadline"]),
]
bad = 0
for what, fields, runs in checks:
    want = sorted(key(o, fields) for o in outcomes(runs[0]))
    for run in runs[1:]:
        got = sorted(key(o, fields) for o in outcomes(run))
        if got != want:
            print(f"{what}: {run} {got} != {runs[0]} {want}")
            bad += 1
    print(f"{what}: {len(want)} agents, {', '.join(runs)}: equal {fields}")
last_ok = {r: [key(o, full) for o in outcomes(r) if o["status"] == "ok"][-1] for r in ("app-restart-edge-2", "restart-edge-2")}
if last_ok["app-restart-edge-2"] != last_ok["restart-edge-2"]:
    print(f"retry after a restart: {last_ok}")
    bad += 1
print(f"retry after a restart: app/ and with nfltr {last_ok['restart-edge-2']}")
sys.exit(1 if bad else 0)
