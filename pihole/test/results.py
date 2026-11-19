#!/usr/bin/env python3
"""The example's judge (scripts/test-pihole.sh, README.md).

results.py judge <evidence dir>
    writes <dir>/results.json from the checks' exit codes, the benches,
    the restart, the machines' listeners, the router's rules and the
    configuration lines;
    exit 1 when a check failed (results.json names it).
results.py readme <results.json>
    writes README.md's measured tables from one results.json.
"""
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EX = os.path.dirname(HERE)

# One TLS 1.3 record's overhead each way (5-byte header, content type, 16-byte tag).
TLS_RECORD = 22


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


def listeners(path, state):
    """Non-loopback sockets in /proc/net/{tcp,udp}{,6} output: TCP listening (0A), UDP unconnected (07)."""
    out = set()
    for line in open(path).read().splitlines():
        f = line.split()
        if len(f) < 4 or f[3] != state or ":" not in f[1] or not f[2].endswith(":0000"):
            continue
        addr, port = f[1].split(":")
        ip = hexaddr(addr)
        if ip.startswith("127.") or ip == "0000:0000:0000:0000:0000:0000:0000:0001":
            continue
        out.add("%s:%d" % ("*" if set(ip) <= set("0.:") else ip, int(port, 16)))
    return sorted(out)


def config_lines():
    files = {}
    for p in sorted(glob.glob(os.path.join(EX, "deploy", "*"))):
        files[os.path.relpath(p, EX)] = sum(1 for l in open(p) if l.strip() and not l.strip().startswith("#"))
    # relay.env: the test's private relay; with the hosted relay, nfltr login replaces it.
    return {"files": files, "lines": sum(files.values()),
            "lines_hosted_relay": sum(v for k, v in files.items() if not k.endswith("relay.env"))}


def bytes_per_query(bench):
    # The stub's TCP query and answer (each with its 2-byte length) inside one TLS record each way.
    return bench["query_bytes"] + 2 + bench["answer_bytes"] + 2 + 2 * TLS_RECORD


def judge(t):
    rules = open(os.path.join(t, "router-rules.txt")).read().splitlines()
    res = {
        "evidence": t,
        "bench_local": load(os.path.join(t, "bench-local.json")),
        "bench": load(os.path.join(t, "bench.json")),
        "bench_tcp_per_query": load(os.path.join(t, "bench-tcp-per-query.json")),
        "restart": load(os.path.join(t, "restart.json")),
        "router_inbound_rules": [r for r in rules if r.startswith("-A PREROUTING") and "DNAT" in r],
        "config": config_lines(),
        "checks": {c["check"]: c["exit"] == 0 for c in jsonl(os.path.join(t, "checks.jsonl"))},
    }
    for m in ("box", "laptop"):
        res[m + "_listeners_not_loopback"] = {
            "tcp": listeners(os.path.join(t, "tcp-%s.txt" % m), "0A"),
            "udp": listeners(os.path.join(t, "udp-%s.txt" % m), "07")}
    checks = res["checks"]
    checks["no inbound rule on the router"] = res["router_inbound_rules"] == []
    # The laptop's sessions go direct when they can (machine certificates,
    # organisation mode): its QUIC sockets are unconnected UDP on ephemeral
    # ports (Linux 32768-60999), kept apart here; anything else fails.
    ll = res["laptop_listeners_not_loopback"]
    res["laptop_udp_direct_path"] = [u for u in ll["udp"] if int(u.rsplit(":", 1)[1]) >= 32768]
    checks["nothing on the laptop listens beyond loopback"] = ll["tcp"] == [] and ll["udp"] == res["laptop_udp_direct_path"]
    checks["answered after a restart within 120 s"] = res["restart"]["answer_after_ms"] <= 120_000
    bn = res["bench"]
    checks["every benchmark query answered"] = bn["cold_ms"]["failures"] == 0 and bn["cached_ms"]["failures"] == 0
    res["bytes_per_query"] = bytes_per_query(bn)
    res["ok"] = all(checks.values())
    with open(os.path.join(t, "results.json"), "w") as f:
        json.dump(res, f, indent=1)
    for k, v in checks.items():
        print("%s %s" % ("ok  " if v else "FAIL", k))
    return 0 if res["ok"] else 1


def readme(path):
    r = load(path)
    paths = [("on the box (UDP, Pi-hole itself)", r["bench_local"]),
             ("nfltr (UDP to the stub, TCP through the mapping)", r["bench"]),
             ("no stub: a new TCP connection per query", r["bench_tcp_per_query"])]
    rows = ["| path | cold p50 / p95 (ms) | cached p50 / p95 (ms) | queries |", "|---|---|---|---|"]
    for name, bn in paths:
        rows.append("| %s | %.1f / %.1f | %.1f / %.1f | %d + %d |" % (
            name, bn["cold_ms"]["p50"], bn["cold_ms"]["p95"], bn["cached_ms"]["p50"], bn["cached_ms"]["p95"],
            bn["cold_ms"]["n"], bn["cached_ms"]["n"]))
    c = r["config"]
    rows += ["", "| lines of configuration | answered after the box's nfltr up restarted | inbound rules on the router |",
             "|---|---|---|",
             "| %d; %d with the hosted relay (%s) | %d ms | %s |" % (
                 c["lines"], c["lines_hosted_relay"],
                 ", ".join("`%s` %d" % (os.path.basename(k), v) for k, v in c["files"].items()),
                 r["restart"]["answer_after_ms"],
                 "; ".join("`%s`" % re.sub(r"^-A PREROUTING ", "", s) for s in r["router_inbound_rules"]) or "none")]
    rows += ["", "| check | result |", "|---|---|"]
    rows += ["| %s | %s |" % (k, "pass" if v else "FAIL") for k, v in r["checks"].items()]
    rows += ["", "Through the relay, a query and its answer carry %d bytes (the stub's TCP query and answer, one TLS "
             "record each way)." % r["bytes_per_query"]]
    p = os.path.join(EX, "README.md")
    s = open(p).read()
    s = re.sub(r"(<!-- ph:results -->\n).*?(<!-- /ph:results -->)", lambda mm: mm.group(1) + "\n".join(rows) + "\n" + mm.group(2),
               s, flags=re.S)
    open(p, "w").write(s)


if __name__ == "__main__":
    if sys.argv[1] == "readme":
        readme(sys.argv[2])
        sys.exit(0)
    sys.exit(judge(sys.argv[2]))
