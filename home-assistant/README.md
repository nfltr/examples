# Home Assistant, reachable from anywhere, exposed to no one

A Home Assistant at home, used from a phone or a laptop away from home.
`nfltr up` on the home machine dials out to the relay and gives Home
Assistant an unlisted HTTPS link (a random host name under the relay's
share domain). The link is end-to-end encrypted (verified mode): TLS ends
on the home machine, and the relay forwards bytes it cannot read. The
router forwards nothing; nothing at home accepts a connection from
outside. Home Assistant's own login guards it; `configuration.yaml`
trusts `nfltr up` as a proxy on loopback, since Home Assistant refuses a
proxied request otherwise.

`make home-assistant` runs the official Home Assistant image (2026.10.4,
pinned by digest; it starts headless in a few seconds, so no stand-in is
needed) on a home network behind NAT and a visitor on the internet, every
machine a container, and judges every claim below by exit codes. The
tables are generated from its `results.json` by `test/report.py`.

| Path | What it is |
|---|---|
| `nfltr/home.yaml` | the `nfltr up` file |
| `ha/configuration.yaml` | Home Assistant's configuration (trusted proxy on loopback) |
| `test/` | `compose.yaml` (home, router, visitor, Home Assistant, the relay, the agent), `probe/` (the visitor: onboarding, checks, bench, port scan), `report.py` (judge and README tables), `Dockerfile` |

## Run it

```
make home-assistant                     # docker (Linux containers: iptables), openssl
python3 home-assistant/test/report.py readme <run>/results.json
```

`HA_EXAMPLE_OUT` names the evidence directory (default: a new directory
under `$TMPDIR`, so the docker host sees the same path): every container's log, the
visitor's JSON per check, the port scans, the router's rules and
`results.json`. A run takes about a minute after the images are pulled
(Home Assistant's is 3.4 GB). The test's networks are 10.236.1.0/24
(home) and 10.236.2.0/24 (internet).

The machines (test/compose.yaml): `home` (out only through the router;
it drops new connections from anywhere but the router, since the Docker
host would otherwise route to it), `router` (NAT out), `visitor` (on the
internet), and `relay` (a private relay standing in for the hosted one).
The link's certificate is a self-signed one the visitor pins (Let's
Encrypt cannot issue for a test network); the visitor connects to the
relay's port with the link's host name, as a browser does.

What the test does: the visitor checks the UI, the REST API with the
owner's token, a state change arriving on the WebSocket (the live updates
the app runs on) and that both APIs refuse a visitor without a token; it
tries ports 80, 443, 8123 and 8443 on the home's public address and on
the home machine itself, and none answers. A link with a guessed name is
refused, the visitor's TLS session must be with the home machine's
certificate (not the relay's), and the agent is killed and started:
timed from the kill until Home Assistant answers again through the same
link.

## Results

<!-- ha:runs -->
- run: 2026-11-19 (Linux, docker, released nfltr and nfltr-relay)
<!-- /ha:runs -->

### Checks

<!-- ha:checks -->
| check | result |
|---|---|
| the UI loads | yes |
| the REST API answers with the owner's token | yes |
| a state change arrives on the WebSocket (live updates) | yes |
| the REST API refuses a visitor without a token (401) | yes |
| the WebSocket refuses a visitor without a token | yes |
| ports of the home's public address that accept a connection (of 80, 443, 8123, 8443) | none |
| inbound rules on the home router | 0 |
| a visitor with a guessed name is refused | yes |
| the visitor's TLS ends at home (the relay cannot read it) | yes |
| the agent killed and started: answering again after | 0.6 s, same link |
<!-- /ha:checks -->

### Latency

Sequential calls after 10 warm-up calls, visitor and home on one host:
this measures what the path visitor -> relay -> `nfltr up` -> Home
Assistant adds, with the visitor's TLS ending at `nfltr up`, not a
phone's network.

<!-- ha:latency -->
| what | n | p50 ms | p95 ms | max ms |
|---|---|---|---|---|
| REST call (`GET /api/`), kept-alive | 300 | 0.39 | 0.67 | 2.8 |
| WebSocket command round trip | 300 | 0.15 | 0.40 | 2.7 |
| state change: REST write to WebSocket event | 20 | 0.62 | 1.08 | 1.1 |
<!-- /ha:latency -->

### Setup

Lines that are not blank and not only a comment, in the files the owner
writes, and the moving parts the owner keeps running:

<!-- ha:effort -->
9 lines in `nfltr/home.yaml` (3), `ha/configuration.yaml` (6); 2 moving parts: nfltr up, running (a machine certificate from nfltr config login); Home Assistant's trusted-proxy setting.
<!-- /ha:effort -->

### Bytes

What a phone or laptop away from home moves through the relay. The cold
load counts the page and the scripts it names; the app loads more scripts
on demand, so it is a lower bound.

<!-- ha:bytes -->
Measured per open: 62470 bytes (WebSocket session: auth, states, config, services); per cold load: 191112 bytes (the page and 2 scripts).
<!-- /ha:bytes -->

## Limits

- A link ends after a day without a visit (the relay's share lifetime:
  24 hours on nfltr.xyz; your own relay's `HTTP_SHARE_TTL`). Each
  visit starts that day again, so a link in use keeps its URL across
  restarts of `nfltr up` and of the relay; one nobody opened for a day
  stops answering, `nfltr up` logs it and lists it `expired` in its
  `/status`, and a restart gives a new link (checked with a 4-second
  lifetime on a private relay, not in this test). A phone left
  unused for more than a day needs the new link.
- The link is unlisted, not secret from whoever holds it: anyone with the
  URL reaches Home Assistant's login.
  Share Basic Auth (`share_auth`) would add a second gate, but Home
  Assistant's app sends its own `Authorization: Bearer` header on API
  calls, which replaces the browser's Basic credentials, so the two do
  not combine.
- The latency is one host's: it shows what the path adds, not the
  phone's network to the relay.
