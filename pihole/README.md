# Your Pi-hole, anywhere

A Pi-hole at home blocks ads and trackers for every device on the home
network. This example keeps that blocking on a laptop away from home with
nfltr, while nothing answers DNS on the home's public address and the home
router forwards no port. `make pihole` runs it with the official Pi-hole
image and judges every claim below by exit codes. The tables are written
from its `results.json` by `test/results.py readme`.

`nfltr up` on the box dials out to a relay and publishes Pi-hole's DNS over
TCP (port 53; DNS over TCP is standard, RFC 7766) and its web interface as
`pihole/dns` and `pihole/web`, end-to-end encrypted in organisation mode.
`nfltr up` on the laptop maps them (as `pihole.pihole/dns` and
`pihole.pihole/web`: agent `pihole` on machine `pihole`) to
`127.0.0.1:5353` and `127.0.0.1:8080`. Operating systems ask their
resolver over UDP, and nfltr's `services:` and `connect:` carry TCP, so a
stub resolver on the laptop (CoreDNS, `deploy/Corefile`; unbound's
`tcp-upstream: yes` does the same) answers the system on `127.0.0.1:53`
and asks Pi-hole over TCP, keeping its connection open between queries.
The router forwards nothing, the box accepts no connection from outside,
and only a machine of your organisation's group `home` (`allow_group:
[home]` on each service; both machines joined with `nfltr org join`, each
with its own key named as it joins: `pihole`, `laptop`) opens a session.
This runs wherever `nfltr up` runs (Linux, macOS, Windows), with no root
beyond binding port 53.

A DoH front (dnsdist, cloudflared) beside Pi-hole, published through an
`http:` share, would serve DNS over HTTPS to a browser or an iOS DNS
profile. A share link answers anyone who has its URL, and every query
reaches Pi-hole from one client; this example does not test it.

**Phones**: this example does not reach them. There is no nfltr app for
iOS or Android. Android's Private DNS takes a hostname and speaks DNS over
TLS (RFC 7858, port 853,
https://android-developers.googleblog.com/2018/04/dns-over-tls-support-in-android-p.html,
read 2026-11-01); a share link serves HTTPS on 443, so it cannot be that
server.

| Path | What it is |
|---|---|
| `client/` | The laptop's DNS client: `once` (an A query; exit 0 when the answer is the wanted one, 3 when it differs, 1 when none came), `wait`, `bench` (cold and cached query latency, bytes), over UDP or TCP |
| `pihole/` | `adlists.list` and `blocklist.txt`: the test has no internet, so gravity reads a small hosts-format blocklist from a file instead of downloading one |
| `deploy/` | `box.yaml`, `laptop.yaml` (the two `nfltr up` files), `Corefile` (the laptop's stub), `relay.env` (this test's private relay; `nfltr config login` replaces it for the hosted one), `box.env`, `laptop.env` (the config holding each machine's relay certificate, enrolled with a single-use code as `nfltr config set-relay --code-file -`, and its organisation enrolment) |
| `test/` | The machines (`compose.yaml`: box, router, laptop, the upstream DNS, the relay), the image, `internet.Corefile` (the upstream DNS: every name is `192.0.2.10`), `results.py` (judge, README tables) |

## Run it at home

Once, make your organisation (`nfltr org init --root file --groups home`,
`nfltr org serve` while machines join) and join both machines to group
`home` (`nfltr org token --name pihole --group home | nfltr org join ...`
on the box, `--name laptop` on the laptop; docs: "Organisation
enrolment"). On the box, beside Pi-hole: `nfltr up -c box.yaml`. On the
laptop: `nfltr up -c laptop.yaml`,
CoreDNS with `deploy/Corefile` (`coredns -conf Corefile`; binding
port 53 may need root), and the system's DNS server set to `127.0.0.1`
(on macOS `networksetup -setdnsservers Wi-Fi 127.0.0.1`; on Linux with
systemd-resolved, `DNS=127.0.0.1` in `resolved.conf`). Pi-hole's web
interface is then `http://127.0.0.1:8080/admin` on the laptop. The test
ran Linux containers only; the macOS and systemd-resolved lines are not
tested.

Two things change for Pi-hole: every query from the laptop reaches it from
`127.0.0.1` (the box's agent), so its per-client statistics show one
client, and the laptop resolves nothing while the box or its agent is
down. A second `forward` target in the Corefile with `policy sequential`
keeps the laptop resolving then, without blocking.

## Run the test

```
make pihole                                  # docker (Linux containers: iptables, tc)
python3 pihole/test/results.py readme <run>/results.json
```

`PIHOLE_OUT` names the evidence directory (default: a new directory
under `$TMPDIR`, so the docker host sees the same path): the binaries, the
provisioned files and container logs, `checks.jsonl` (every check's exit
code), each bench, each machine's `/proc/net/{tcp,udp}`, the router's
rules and `results.json`.

The machines (`test/compose.yaml`): `box` (Pi-hole `2026.10.1` pinned by
digest; out only through the router, which adds 10 ms each way between
home and the outside; new connections from the home network dropped
unless the router sends them), `router` (NAT out), `laptop`, `internet`
(CoreDNS as Pi-hole's upstream) and `relay`, a private relay outside the
home (TLS self-signed, pinned). Pi-hole's blocklist is a file.

In order: Pi-hole on the box itself (the baseline), 100 cold queries (a
new name each, so Pi-hole asks its upstream) and 100 cached ones (one
name) from the laptop, an ad and a tracker domain answered `0.0.0.0` and a
normal domain answered by the upstream, Pi-hole's admin page from the
laptop through the mapping, refusals (`nfltr cat pipe` from a machine
without a relay certificate exits 2, from a machine not enrolled in the
organisation 4, from one outside the group 10, the laptop 0), DNS over UDP
and TCP to the home's public address and its ports 80 and 443 (each must
get nothing), the listeners and rules, then the box's `nfltr up` killed
and started, timed until the laptop's next answer. The test also runs
30 + 30 queries straight to the mapping with a new TCP connection each,
as a client that does not keep its connection would.

## Results

<!-- ph:results -->
| path | cold p50 / p95 (ms) | cached p50 / p95 (ms) | queries |
|---|---|---|---|
| on the box (UDP, Pi-hole itself) | 21.7 / 23.5 | 0.1 / 0.1 | 100 + 100 |
| nfltr (UDP to the stub, TCP through the mapping) | 42.9 / 46.7 | 21.3 / 25.0 | 100 + 100 |
| no stub: a new TCP connection per query | 108.4 / 131.5 | 85.7 / 93.2 | 30 + 30 |

| lines of configuration | answered after the box's nfltr up restarted | inbound rules on the router |
|---|---|---|
| 21; 17 with the hosted relay (`Corefile` 6, `box.env` 1, `box.yaml` 4, `laptop.env` 3, `laptop.yaml` 3, `relay.env` 4) | 2160 ms | none |

| check | result |
|---|---|
| an ad domain is blocked | pass |
| a tracker domain is blocked | pass |
| a normal domain resolves | pass |
| the admin page answers through the mapping | pass |
| the machine's certificate opens a session | pass |
| a machine without a certificate is refused | pass |
| a machine not enrolled is refused | pass |
| a machine outside the group is refused | pass |
| no DNS answer on the home's public address (udp) | pass |
| no DNS answer on the home's public address (tcp) | pass |
| the home's port 80 is closed | pass |
| the home's port 443 is closed | pass |
| no inbound rule on the router | pass |
| nothing on the laptop listens beyond loopback | pass |
| answered after a restart within 120 s | pass |
| every benchmark query answered | pass |

Through the relay, a query and its answer carry 145 bytes (the stub's TCP query and answer, one TLS record each way).
<!-- /ph:results -->

Cached queries take the 20 ms round trip through the home router. Without
a stub that keeps its connection, every query opens a session and an
end-to-end TLS handshake through the relay (the last row); CoreDNS keeps
it open between queries (and closes it after 10 s idle, its `expire`
default per https://coredns.io/plugins/forward/, read 2026-11-01, so the
first query after a pause pays it once). The relay here sits on the
laptop's side of the home's round trip; a relay far from both machines
adds its distance to every query.
