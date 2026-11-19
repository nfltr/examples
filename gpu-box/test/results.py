#!/usr/bin/env python3
"""The example's judge (scripts/test-gpu-box.sh, README.md).

results.py judge <evidence dir>
    writes <dir>/results.json from the checks' exit codes, the benches,
    the restart, the box's and laptop's listeners and the router's rules;
    exit 1 when a check failed (results.json names it).
results.py readme <results.json>
    writes README.md's measured tables from one results.json.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EX = os.path.dirname(HERE)


def load(path):
    with open(path) as f:
        return json.load(f)


def jsonl(path):
    with open(path) as f:
        return [json.loads(l) for l in f if l.strip()]


def hexaddr(h):
    if len(h) == 8:
        return ".".join(str(x) for x in bytes.fromhex(h)[::-1])
    s = "".join(bytes.fromhex(h[i:i + 8])[::-1].hex() for i in range(0, 32, 8))
    if s.startswith("0" * 20 + "ffff"):
        return ".".join(str(x) for x in bytes.fromhex(s[24:]))
    return ":".join(s[i:i + 4] for i in range(0, 32, 4))


def listeners(path):
    """Non-loopback TCP listeners in /proc/net/tcp{,6} output."""
    out = set()
    for line in open(path).read().splitlines():
        f = line.split()
        if len(f) < 4 or f[3] != "0A" or ":" not in f[1]:
            continue
        addr, port = f[1].split(":")
        ip = hexaddr(addr)
        if ip.startswith("127.") or ip == "0000:0000:0000:0000:0000:0000:0000:0001":
            continue
        out.add("%s:%d" % ("*" if set(ip) <= set("0.:") else ip, int(port, 16)))
    return sorted(out)


def stream_bytes_per_token(bench):
    return round((bench["stream_bytes"] - bench["stream_request_bytes"]) / bench["tokens"], 1)


def judge(t):
    checks = {c["check"]: c["exit"] == 0 for c in jsonl(os.path.join(t, "checks.jsonl"))}
    rules = open(os.path.join(t, "router-rules.txt")).read().splitlines()
    res = {
        "evidence": t,
        "local_bench": load(os.path.join(t, "local-bench.json")),
        "bench": load(os.path.join(t, "bench.json")),
        "restart": load(os.path.join(t, "restart.json")),
        "box_listeners_not_loopback": listeners(os.path.join(t, "net-box.txt")),
        "laptop_listeners_not_loopback": listeners(os.path.join(t, "net-laptop.txt")),
        "router_inbound_rules": [r for r in rules if r.startswith("-A PREROUTING") and "DNAT" in r],
        "checks": checks,
    }
    checks["nothing on the box or the laptop listens beyond loopback"] = (
        res["box_listeners_not_loopback"] == [] and res["laptop_listeners_not_loopback"] == [])
    checks["no inbound rule on the router"] = res["router_inbound_rules"] == []
    checks["answered after nfltr up on the box restarted, within 120 s"] = res["restart"]["answer_after_ms"] <= 120_000
    res["stream_bytes_per_token"] = stream_bytes_per_token(res["bench"])
    res["ok"] = all(checks.values())
    with open(os.path.join(t, "results.json"), "w") as f:
        json.dump(res, f, indent=1)
    for k, v in checks.items():
        print("%s %s" % ("ok  " if v else "FAIL", k))
    return 0 if res["ok"] else 1


def readme(path):
    r = load(path)
    rows = ["| | completion p50 / p95 (ms) | first token p50 / p95 (ms) | streamed answer p50 (ms) |", "|---|---|---|---|"]
    for name, bn in (("on the box", r["local_bench"]), ("from the laptop, through nfltr", r["bench"])):
        rows.append("| %s | %.1f / %.1f | %.1f / %.1f | %.1f |" % (
            name, bn["completion_ms"]["p50"], bn["completion_ms"]["p95"], bn["ttft_ms"]["p50"], bn["ttft_ms"]["p95"],
            bn["stream_ms"]["p50"]))
    rows += ["", "| check | result |", "|---|---|"]
    rows += ["| %s | %s |" % (k, "pass" if v else "FAIL") for k, v in r["checks"].items()]
    rows += ["", "After `nfltr up` on the box was killed and started, the laptop's next answer came %d ms later." %
             r["restart"]["answer_after_ms"],
             "", "Through the relay, a streamed answer carries %.1f bytes per token (OpenAI-style streaming sends one JSON "
             "chunk per token)." % r["stream_bytes_per_token"]]
    p = os.path.join(EX, "README.md")
    s = open(p).read()
    s = re.sub(r"(<!-- gb:results -->\n).*?(<!-- /gb:results -->)", lambda mm: mm.group(1) + "\n".join(rows) + "\n" + mm.group(2),
               s, flags=re.S)
    open(p, "w").write(s)


if __name__ == "__main__":
    if sys.argv[1] == "readme":
        readme(sys.argv[2])
        sys.exit(0)
    sys.exit(judge(sys.argv[2]))
