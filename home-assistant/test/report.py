#!/usr/bin/env python3
"""The Home Assistant example's judge and report
(scripts/test-home-assistant.sh, README.md).

report.py judge <evidence dir>
    writes <dir>/results.json from the visitor's checks, benches, port
    scans, router rules, the restart and the setup's configuration lines; exit 1 when a check failed (results.json
    names it).
report.py readme <results.json>
    rewrites the text between each <!-- ha:NAME --> and <!-- /ha:NAME -->
    in ../README.md.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EX = os.path.dirname(HERE)
README = os.path.join(EX, "README.md")
# What the setup asks its owner to configure and keep running (README.md
# "Setup"); the files are counted below.
FILES = ["nfltr/home.yaml", "ha/configuration.yaml"]
MOVING_PARTS = [
    "nfltr up, running (a machine certificate from nfltr config login)",
    "Home Assistant's trusted-proxy setting",
]


def load(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return default


def code_lines(path):
    n = 0
    with open(os.path.join(EX, path)) as f:
        for line in f:
            s = line.strip()
            if s and not s.startswith("#"):
                n += 1
    return n


def judge(d):
    res = {"failed": []}
    res["check"] = load(os.path.join(d, "check.json"), {})
    res["bench"] = load(os.path.join(d, "bench.json"), {})
    res["public_open_ports"] = load(os.path.join(d, "ports-public.json"), {}).get("open")
    res["home_machine_open_ports"] = load(os.path.join(d, "ports-home.json"), {}).get("open")
    res["router_inbound_rules"] = [l for l in open(os.path.join(d, "router-rules.txt")).read().splitlines()
                                   if "DNAT" in l or ("-d 10.236.1.10" in l and "ACCEPT" in l)]
    res["files"] = {f: code_lines(f) for f in FILES}
    res["config_lines"] = sum(res["files"].values())
    res["moving_parts"] = MOVING_PARTS
    for name, c in res["check"].items():
        if not c.get("pass"):
            res["failed"].append(name)
    if not res["check"]:
        res["failed"].append("no checks")
    if res["public_open_ports"] != [] or res["home_machine_open_ports"] != [] or res["router_inbound_rules"]:
        res["failed"].append("an inbound port or rule at home")
    res["guessed_link_refused"] = load(os.path.join(d, "guessed-link.json"), {}).get("pass") is True
    if not res["guessed_link_refused"]:
        res["failed"].append("a guessed link was not refused")
    certs = load(os.path.join(d, "certs.json"), {})
    res["visitor_tls_ends_at_home"] = bool(certs) and certs["link_cert_sha256"] != certs["relay_cert_sha256"]
    if not res["visitor_tls_ends_at_home"]:
        res["failed"].append("the visitor's TLS is not the home's certificate")
    res["agent_restart_ms"] = load(os.path.join(d, "restart.json"), {}).get("ms")
    after_restart = load(os.path.join(d, "check-after-restart.json"), {})
    res["agent_restart_check"] = bool(after_restart) and all(c.get("pass") for c in after_restart.values())
    if res["agent_restart_ms"] is None or not res["agent_restart_check"]:
        res["failed"].append("no recovery after the agent restart")
    res["agent_to_first_answer_s"] = load(os.path.join(d, "start.json"), {}).get("agent_to_first_answer_s")
    res["ha_ready_s"] = load(os.path.join(d, "ha.json"), {}).get("ha_ready_s")
    res["wall_s"] = load(os.path.join(d, "wall.json"), {}).get("wall_s")
    res["ha_image"] = "homeassistant/home-assistant:2026.10.4 (by digest)"
    res["pass"] = not res["failed"]
    with open(os.path.join(d, "results.json"), "w") as f:
        json.dump(res, f, indent=2)
    for x in res["failed"]:
        print("FAIL:", x, file=sys.stderr)
    return 0 if res["pass"] else 1


def table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    return "\n".join(out + ["| " + " | ".join(r) + " |" for r in rows])


def ports(v):
    return "none" if not v else ", ".join(map(str, v))


def readme(path):
    r = load(path)
    secs = {}
    yes = lambda b: "yes" if b else "no"
    rows = []
    for name, label in [("ui", "the UI loads"), ("rest_api", "the REST API answers with the owner's token"),
                        ("websocket_live_update", "a state change arrives on the WebSocket (live updates)"),
                        ("rest_refused_without_token", "the REST API refuses a visitor without a token (401)"),
                        ("websocket_refused_without_token", "the WebSocket refuses a visitor without a token")]:
        rows.append([label, yes(r["check"].get(name, {}).get("pass"))])
    rows.append(["ports of the home's public address that accept a connection (of 80, 443, 8123, 8443)",
                 ports(r["public_open_ports"])])
    rows.append(["inbound rules on the home router", str(len(r["router_inbound_rules"]))])
    rows.append(["a visitor with a guessed name is refused", yes(r["guessed_link_refused"])])
    rows.append(["the visitor's TLS ends at home (the relay cannot read it)", yes(r["visitor_tls_ends_at_home"])])
    rows.append(["the agent killed and started: answering again after", "%.1f s, same link" % (r["agent_restart_ms"] / 1000)])
    secs["checks"] = table(["check", "result"], rows)

    rows = []
    for k, label in [("rest", "REST call (`GET /api/`), kept-alive"), ("websocket_round_trip", "WebSocket command round trip"),
                     ("live_update", "state change: REST write to WebSocket event")]:
        b = r["bench"][k]
        rows.append([label, str(b["n"]), "%.2f" % b["p50_ms"], "%.2f" % b["p95_ms"], "%.1f" % b["max_ms"]])
    secs["latency"] = table(["what", "n", "p50 ms", "p95 ms", "max ms"], rows)

    files = ", ".join("`%s` (%d)" % kv for kv in r["files"].items())
    secs["effort"] = ("%d lines in %s; %d moving parts: %s." %
                      (r["config_lines"], files, len(r["moving_parts"]), "; ".join(r["moving_parts"])))

    b = r["bench"]
    secs["bytes"] = ("Measured per open: %d bytes (WebSocket session: auth, states, config, services); per cold load: %d bytes "
                     "(the page and %d scripts)." % (b["open_session_bytes"], b["cold_load_bytes"], b["cold_load_scripts"]))
    with open(README) as f:
        text = f.read()
    for k, v in secs.items():
        text, n = re.subn(r"(<!-- ha:%s -->\n).*?(<!-- /ha:%s -->)" % (k, k), lambda mo: mo.group(1) + v + "\n" + mo.group(2),
                          text, flags=re.S)
        if n != 1:
            raise SystemExit("README.md: no section %s" % k)
    with open(README, "w") as f:
        f.write(text)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("judge", "readme"):
        raise SystemExit(__doc__)
    sys.exit(judge(sys.argv[2]) if sys.argv[1] == "judge" else readme(sys.argv[2]))
