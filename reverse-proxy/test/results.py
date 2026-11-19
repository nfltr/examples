#!/usr/bin/env python3
"""The reverse-proxy example's judge and report
(scripts/test-reverse-proxy.sh, README.md).

results.py judge <evidence dir>
    writes <dir>/results.json from the checks' exit codes, what the
    services saw, the benches, port scans, listeners, router rules, the
    restarts and the configuration lines; exit 1 when a check failed (results.json names it).
results.py readme <results.json>
    rewrites the text between <!-- rp:results --> and <!-- /rp:results -->
    in ../README.md.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EX = os.path.dirname(HERE)
README = os.path.join(EX, "README.md")
ARMS = ["caddy", "traefik"]
CHECKS = [  # (check, what it shows)
    ("route-host-app", "app. host: / reaches the photos service"),
    ("route-path-api", "app. host: /api/ reaches the api service (path route)"),
    ("route-host-admin", "admin. host reaches the admin service with the login, and it gets X-Auth-User from the proxy"),
    ("auth-none-refused", "admin. host without a login: 401 from the proxy"),
    ("auth-wrong-refused", "admin. host with a wrong password: 401 from the proxy"),
    ("headers-app", "the service's view of the request (table below)"),
    ("headers-forged", "the service's view when the visitor forges X-Forwarded-For, X-Real-Ip, X-Forwarded-Host and -Proto"),
    ("headers-admin", "the admin service's view of the request"),
    ("websocket", "a WebSocket through the proxy: upgrade, then 100 echoes"),
    ("guessed-link-refused", "a link with a guessed name is refused"),
]
FILES = {  # what each arm asks its owner to write and keep, counted
    "caddy": ["deploy/nfltr.yaml", "deploy/hosts", "deploy/caddy/Caddyfile"],
    "traefik": ["deploy/nfltr.yaml", "deploy/hosts", "deploy/traefik/traefik.yml", "deploy/traefik/dynamic/routes.yml"],
}
MOVING_PARTS = ["nfltr up, running (a machine certificate from nfltr config login)", "the home names in /etc/hosts",
                "the proxy, on loopback only"]
def load(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return default


def code_lines(path):
    with open(os.path.join(EX, path)) as f:
        return sum(1 for l in f if l.strip() and not l.strip().startswith("#"))


def listeners(path):
    """(address, port) of the TCP sockets listening in /proc/net/tcp{,6}."""
    out = []
    try:
        lines = open(path).read().splitlines()
    except FileNotFoundError:
        return None
    for l in lines:
        f = l.split()
        if len(f) < 4 or f[3] != "0A" or ":" not in f[1]:
            continue
        a, p = f[1].split(":")
        if len(a) == 8:
            ip = ".".join(str(int(a[i:i + 2], 16)) for i in (6, 4, 2, 0))
        else:
            ip = "::1" if a == "00000000000000000000000001000000" else ("::" if set(a) == {"0"} else a)
        out.append((ip, int(p, 16)))
    return sorted(set(out))


def public(ip):
    return not (ip.startswith("127.") or ip == "::1")


def view(o):
    s = (o or {}).get("seen") or {}
    h = s.get("headers") or {}
    return {"host": s.get("host"), "peer": (s.get("remote_addr") or "").rsplit(":", 1)[0],
            "x_forwarded_for": h.get("X-Forwarded-For"), "x_real_ip": h.get("X-Real-Ip"),
            "x_forwarded_proto": h.get("X-Forwarded-Proto"), "x_forwarded_host": h.get("X-Forwarded-Host"),
            "via": h.get("Via"), "x_auth_user": h.get("X-Auth-User")}


def judge(d):
    run = load(os.path.join(d, "run.json"), {})
    visitor = run.get("visitor")
    exits = {}
    with open(os.path.join(d, "checks.jsonl")) as f:
        for l in f:
            c = json.loads(l)
            exits[(c["arm"], c["check"])] = c["exit"]
    res = {"visitor": visitor, "wall_s": run.get("wall_s"), "arms": {}, "failed": [],
           "images": {"caddy": "caddy:2.10.2-alpine (by digest)", "traefik": "traefik:v3.5 (3.5.6, by digest)"}}
    for arm in ARMS:
        p = lambda n: os.path.join(d, arm, n)
        a = {"checks": {}, "files": {f: code_lines(f) for f in FILES[arm]}, "moving_parts": MOVING_PARTS}
        a["config_lines"] = sum(a["files"].values())
        for name, _ in CHECKS:
            rc = exits.get((arm, name))
            a["checks"][name] = rc == 0
            if rc != 0:
                res["failed"].append("%s: %s (exit %s)" % (arm, name, rc))
        a["seen_app"] = view(load(p("headers-app.json")))
        a["seen_admin"] = view(load(p("headers-admin.json")))
        a["seen_forged"] = view(load(p("headers-forged.json")))
        first = (a["seen_forged"]["x_forwarded_for"] or "").split(",")[0].strip()
        a["checks"]["forged-address-not-first"] = first == visitor
        if first != visitor:
            res["failed"].append("%s: a forged X-Forwarded-For reached the service as the client" % arm)
        ws = load(p("websocket.json"), {})
        a["seen_websocket"] = view(ws)
        xff = (a["seen_app"]["x_forwarded_for"] or "").split(",")[0].strip()
        a["checks"]["service-sees-visitor"] = xff == visitor and a["seen_app"]["x_forwarded_proto"] == "https"
        if not a["checks"]["service-sees-visitor"]:
            res["failed"].append("%s: the service does not see the visitor's address and https" % arm)
        a["seen_app_untrusted"] = view(load(p("headers-app-untrusted.json")))
        a["bench"] = load(p("bench.json"))
        a["websocket_echo"] = ws.get("echo")
        a["websocket_upgrade_ms"] = ws.get("upgrade_ms")
        a["restart"] = load(p("restart.json"))
        if not a["restart"]:
            res["failed"].append("%s: no answer after the restart" % arm)
        a["public_open_ports"] = load(p("ports-public.json"), {}).get("open")
        ls = listeners(p("net-server.txt"))
        a["server_public_listeners"] = None if ls is None else ["%s:%d" % x for x in ls if public(x[0])]
        rules = open(p("router-rules.txt")).read().splitlines() if os.path.exists(p("router-rules.txt")) else []
        a["router_inbound_rules"] = [l for l in rules if "DNAT" in l or "-d 10.234.1.10" in l]
        ok = a["public_open_ports"] == [] and not a["router_inbound_rules"] and a["server_public_listeners"] == []
        a["checks"]["no-inbound-port"] = ok
        if not ok:
            res["failed"].append("%s: a port open on the home's public address, an inbound rule or a public listener" % arm)
        res["arms"][arm] = a
    res["pass"] = not res["failed"]
    with open(os.path.join(d, "results.json"), "w") as f:
        json.dump(res, f, indent=2)
    for x in res["failed"]:
        print("FAIL:", x, file=sys.stderr)
    return 0 if res["pass"] else 1


def table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    return "\n".join(out + ["| " + " | ".join(r) + " |" for r in rows])


def readme(path):
    r = load(path)
    A = r["arms"]
    vis = r["visitor"]
    yes = lambda b: "pass" if b else "FAIL"

    def show(v, arm):
        if v is None:
            return "(none)"
        v = v.replace(vis, "visitor").replace("127.0.0.1", "loopback")
        v = re.sub(r"[a-z0-9]{20,}\.share\.test", "the link's name", v)
        return "`%s`" % v

    out = []
    rows = []
    for name, label in CHECKS + [("service-sees-visitor", "the service can tell the visitor's address (X-Forwarded-For) and that it came over https"),
                                 ("forged-address-not-first", "a forged X-Forwarded-For does not become the address the service reads first"),
                                 ("no-inbound-port", "nothing open on the home's public address, no inbound rule, nothing on the server listening beyond loopback")]:
        rows.append([label] + [yes(A[a]["checks"][name]) for a in ARMS])
    out.append(table(["check"] + ARMS, rows))

    rows = []
    fields = [("peer", "connection from"), ("host", "Host"), ("x_forwarded_for", "X-Forwarded-For"),
              ("x_real_ip", "X-Real-Ip"), ("x_forwarded_proto", "X-Forwarded-Proto"),
              ("x_forwarded_host", "X-Forwarded-Host"), ("via", "Via")]
    cols = [(a, "seen_app") for a in ARMS] + [(a, "seen_app_untrusted") for a in ARMS]
    heads = ARMS + [a + ", no trust line" for a in ARMS]
    for k, label in fields:
        rows.append([label] + [show(A[a][s][k], a) for a, s in cols])
    frows = []
    for k, label in fields[2:6]:
        frows.append([label] + [show(A[a]["seen_forged"][k], a).replace("203.0.113.9", "forged") for a in ARMS])
    forged = "The same GET with forged headers (`X-Forwarded-For` and `X-Real-Ip` 203.0.113.9, `X-Forwarded-Host` evil.example, `X-Forwarded-Proto` http):\n\n" + table(["header"] + ARMS, frows)
    out.append("What the photos service saw of one GET (`visitor` is the visitor's own address, %s here; "
               "`loopback` is 127.0.0.1):\n\n" % vis + table(["header"] + heads, rows))

    out.append(forged)
    rows = []
    for a in ARMS:
        b, w = A[a]["bench"], A[a]["websocket_echo"]
        rows.append([a, "%.1f / %.1f" % (b["p50_ms"], b["p95_ms"]), "%.1f / %.1f" % (w["p50_ms"], w["p95_ms"]),
                     "%.0f" % A[a]["websocket_upgrade_ms"], "%.1f s (%s)" % (A[a]["restart"]["ms"] / 1000, A[a]["restart"]["service"])])
    out.append(table(["arm", "GET p50 / p95 (ms, n=200, kept alive)", "WebSocket echo p50 / p95 (ms, n=100)",
                      "WebSocket open (ms, new connection)", "answering again after a kill and start of"], rows))

    rows = []
    for a in ARMS:
        files = ", ".join("`%s` %d" % kv for kv in A[a]["files"].items())
        rows.append([a, "%d (%s)" % (A[a]["config_lines"], files), "%d: %s" % (len(A[a]["moving_parts"]), "; ".join(A[a]["moving_parts"]))])
    out.append(table(["arm", "lines of configuration", "moving parts"], rows))

    out.append("From one run (%d s wall time)." % r["wall_s"])
    body = "\n\n".join(out) + "\n"
    with open(README) as f:
        text = f.read()
    text, n = re.subn(r"(<!-- rp:results -->\n).*?(<!-- /rp:results -->)", lambda mo: mo.group(1) + body + mo.group(2), text, flags=re.S)
    if n != 1:
        raise SystemExit("README.md: no rp:results section")
    with open(README, "w") as f:
        f.write(text)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("judge", "readme"):
        raise SystemExit(__doc__)
    sys.exit(judge(sys.argv[2]) if sys.argv[1] == "judge" else readme(sys.argv[2]))
