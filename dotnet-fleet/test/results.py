"""One run's measurements: results.py <evidence dir> writes results.json
there and prints a summary.

bench rows (both stacks: app, with-nfltr), restart recovery, streamed progress timing, time
to ready, the migration's apply time, each fleet machine's TCP listeners
that are not loopback (from /proc/net/tcp*: each one needs an inbound
firewall, NAT or ingress rule), the processes on the fleet's machines, and
the certificates and private keys provisioning made. The relay is not a
fleet machine (hosted, it is not the organization's to run). Exit 1 when a
machine listens on a non-loopback address with nfltr.
"""
import glob
import json
import os
import re
import subprocess
import sys

t = sys.argv[1]
MACHINES = ("controlplane", "edge-1", "edge-2", "edge-3")


def jsonl(path):
    return [json.loads(l) for l in open(path) if l.startswith("{")]


def listeners(path):
    """Non-loopback TCP listeners in /proc/net/tcp and tcp6 text."""
    out = []
    for line in open(path):
        f = line.split()
        if len(f) < 4 or f[3] != "0A" or ":" not in f[1]:
            continue
        addr, port = f[1].split(":")
        port = int(port, 16)
        if len(addr) == 8:
            if addr.endswith("7F"):  # 127.0.0.0/8, little endian
                continue
            ip = ".".join(str(int(addr[i:i + 2], 16)) for i in (6, 4, 2, 0))
        else:
            if addr == "00000000000000000000000001000000" or (addr[16:24] == "FFFF0000" and addr.endswith("7F")):
                continue  # ::1, ::ffff:127.x
            ip = "::" if set(addr) == {"0"} else addr
        out.append(f"{ip}:{port}")
    return sorted(set(out))


def processes(path):
    apps = sidecars = 0
    for line in open(path):
        if "docker-init" in line:
            continue
        if re.search(r"\bdotnet (Agent|ControlPlane)\.dll", line):
            apps += 1
        elif re.search(r"/nfltr up\b", line):
            sidecars += 1
    return {"app": apps, "sidecar": sidecars}


def certs(paths):
    """ca: issued another certificate here; ca_issued: issued by one."""
    names = []
    for p in paths:
        text = subprocess.run(["openssl", "x509", "-in", p, "-noout", "-subject", "-issuer"], capture_output=True, text=True, check=True).stdout
        names.append((re.search(r"subject=\s*(.*)", text).group(1), re.search(r"issuer=\s*(.*)", text).group(1)))
    issuers = {i for s, i in names if s != i}
    r = {"ca": 0, "ca_issued": 0}
    for s, i in names:
        r["ca" if s in issuers else "ca_issued"] += 1
    return r


bench = jsonl(f"{t}/bench.jsonl")
e2ee = {"edge-1": True, "edge-2": True, "edge-3": False}
for r in bench:
    # app: TLS to the control plane; with-nfltr: sessions are the control plane's e2ee service
    r["e2ee"] = None if r["stack"] == "app" else (True if r["via"] == "session" else e2ee[r["agent"]])
restarts = []
for name in ("app-restart-edge-2", "restart-edge-1", "restart-edge-2"):
    kill = json.load(open(f"{t}/{name}.times"))["kill_ms"]
    outs = jsonl(f"{t}/{name}.out")
    restarts.append({
        "restart": name,
        "unavailable_after_kill_ms": next(o for o in outs if o["status"] == "unavailable")["endUnixMs"] - kill,
        "ok_call_started_after_kill_ms": next(o for o in outs if o["status"] == "ok")["startUnixMs"] - kill,
        "attempts": len(outs)})
streams = [{"run": name, "agent": o["agent"], "progress": o["progress"],
            "first_progress_ms": round(o["firstProgressMs"], 1), "result_ms": round(o["ms"], 1)}
           for name in ("app-b-session", "a-mapping", "a-dial", "b-session") for o in jsonl(f"{t}/{name}.out")]
stacks = {}
for stack in ("app", "with-nfltr"):
    stacks[stack] = {
        "ready_ms": json.load(open(f"{t}/ready-{stack}.json"))["ready_ms"],
        "listeners": {m: listeners(f"{t}/net-{stack}-{m}.txt") for m in MACHINES},
        "processes": processes(f"{t}/top-{stack}.txt"),
    }
# What provisioning made: in app/, the fleet's CA (its key kept off the
# fleet) and the control plane's certificate; with nfltr, the relay
# certificate every sidecar presents (machine.json beside its config,
# renewed by nfltr).
stacks["app"]["certificates"] = certs(sorted(glob.glob(f"{t}/tls/*.crt")))
stacks["app"]["private_keys"] = len(glob.glob(f"{t}/tls/*.key")) + len(glob.glob(f"{t}/ca.key"))
stacks["with-nfltr"]["machine_certificates"] = 1 if all(os.path.exists(f"{t}/fleet/{m}/machine.json") for m in ("controlplane", "edge-1", "edge-2", "edge-3")) else 0
# edge-2's customer site: what its HTTP proxy let through (CONNECTs per
# target) and refused.
for stack in ("app", "with-nfltr"):
    lines = jsonl(f"{t}/site-proxy-{stack}.jsonl")
    targets = {}
    for l in lines:
        if l["allowed"]:
            targets[l["target"]] = targets.get(l["target"], 0) + 1
    stacks[stack]["site_proxy"] = {"connects": targets, "refused": sum(not l["allowed"] for l in lines)}
migration = jsonl(f"{t}/migrate.out")[-1]
json.dump({"bench": bench, "restarts": restarts, "streams": streams, "stacks": stacks, "migration": migration},
          open(f"{t}/results.json", "w"), indent=1)

print(f"{'stack':10} {'via':8} {'agent':7} {'e2ee':5} {'fresh':5} {'steps':>5} {'n':>4} {'p50 ms':>8} {'p95 ms':>8}")
for r in bench:
    print(f"{r['stack']:10} {r['via']:8} {r['agent']:7} {str(r['e2ee']).lower():5} {str(r['fresh']).lower():5} {r['steps']:>5} {r['n']:>4} {r['p50_ms']:>8} {r['p95_ms']:>8}")
for r in streams:
    print(f"{r['run']} {r['agent']}: {r['progress']} progress updates, the first after {r['first_progress_ms']} ms, the result after {r['result_ms']} ms")
for r in restarts:
    print(f"{r['restart']}: UNAVAILABLE {r['unavailable_after_kill_ms']} ms after the kill; the first ok call started "
          f"{r['ok_call_started_after_kill_ms']} ms after it ({r['attempts']} attempts)")
for stack, s in stacks.items():
    print(f"{stack}: ready {s['ready_ms']} ms; non-loopback listeners {s['listeners']}; processes {s['processes']}")
print(f"app: certificates {stacks['app']['certificates']}; private keys {stacks['app']['private_keys']}; "
      f"with-nfltr: a relay machine certificate on every machine: {bool(stacks['with-nfltr']['machine_certificates'])}")
for stack, s in stacks.items():
    print(f"{stack}: edge-2's site proxy let through {s['site_proxy']['connects']}, refused {s['site_proxy']['refused']}")
print(f"patch: {migration['files']} files, applied in {migration['apply_ms']} ms")
exposed = {m: l for m, l in stacks["with-nfltr"]["listeners"].items() if l}
if exposed:
    print(f"FAIL: with nfltr these machines listen on the network: {exposed}")
    sys.exit(1)
if not any(stacks["app"]["listeners"].values()):
    print("FAIL: no listener in app/: /proc/net/tcp was not read")
    sys.exit(1)
