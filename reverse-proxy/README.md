# nfltr with the reverse proxy you already run

A home lab or small office with Caddy or Traefik in front of several
services: one host name per app, paths within a host, a login in front of
the admin pages, headers the apps rely on. This example keeps all of that
and puts `nfltr up` in front of the proxy as the public entry. `make
reverse-proxy` runs it with Caddy and with Traefik and judges every claim
below by exit codes; the tables are written from its `results.json` by
`test/results.py readme`.

`nfltr up` on the home server dials out to the relay and gives each site
an unlisted HTTPS link (a random host name under the relay's share
domain). The links are end-to-end encrypted (verified mode): TLS ends at
`nfltr up` on the server, and the relay forwards bytes it cannot read.
`nfltr up` hands each request to the proxy on loopback with the site's
home name as `Host` (`host_header: rewrite`), so the proxy's routes match
its home names; the proxy trusts loopback for `X-Forwarded-For`. The
router forwards nothing and the proxy listens on loopback only.

Each visit keeps a link alive for another day, across restarts of
`nfltr up`; a link nobody opens for a day ends, and the next start prints
a new one (https://nfltr.xyz/docs).

The proxy keeps routing by host and path, the Basic auth login and the
header it adds for the admin service. TLS and certificates are `nfltr
up`'s: it holds the links' certificate.

**Why `http:` and not an end-to-end `tcp:` service**: a `tcp:` service
would let the proxy terminate TLS with its own certificates, but every
visitor would need `nfltr` running (a `connect:` mapping or `nfltr dial`)
to reach it, which is not a public entry. A TCP session also carries no
client address, so the proxy would see every connection from `127.0.0.1`
with no `X-Forwarded-For` (`tcp:` was not run here). With `http:` a
browser or phone opens the link with nothing installed, and `nfltr up`
passes the address the relay accepted the visitor's connection from.

| Path | What it is |
|---|---|
| `svc/` | The stand-in services (photos, api, admin): each answers with what it saw (host, path, peer, proxy headers) as JSON, and `/ws` is a WebSocket that sends the same, then echoes |
| `deploy/` | `nfltr.yaml` (the `nfltr up` file), `hosts` (the home names), `caddy/Caddyfile`, `traefik/` (`traefik.yml`, `dynamic/routes.yml`) |
| `test/` | `compose.yaml` (server, router, visitor, the services, Caddy, Traefik, the relay, the agent), `probe/` (the visitor), `results.py` (judge, README tables), `Dockerfile` |

The routes: `app.home.arpa/` to photos, `app.home.arpa/api/` to api,
`admin.home.arpa` to admin behind Basic auth (user `owner`), with the
proxy adding `X-Auth-User`. `home.arpa` is the name space for home
networks, resolved to loopback by the line in `deploy/hosts`.

## The headers, in short

What the services see when the proxy sits behind `nfltr up`. Measured
(tables below):

- **The visitor's address**: `X-Forwarded-For` is `<visitor>,
  127.0.0.1`: `nfltr up` sets the visitor's address, and the proxy,
  trusting loopback, appends the hop it got the request from. An app that
  reads the first entry sees the visitor; one that reads the last entry
  (or the connection's peer) sees `127.0.0.1`. `X-Real-Ip` is the
  visitor: `nfltr up` sets it and both proxies pass it on.
- **Without the trust line** (`trusted_proxies` in Caddy, `trustedIPs` in
  Traefik), both proxies replace `X-Forwarded-For` with `127.0.0.1` and
  `X-Forwarded-Proto` with `http`; apps then see every visitor as the
  server itself and build `http://` links (Caddy still passes `nfltr
  up`'s `X-Real-Ip`; Traefik replaces it with `127.0.0.1` too). The line
  is required.
- **`X-Forwarded-Host`** is the link's name; `Host` is the home name the
  proxy routes on. An app that builds absolute URLs from
  `X-Forwarded-Host` gets the link the visitor used.
- **Forged headers**: a visitor that sends its own `X-Forwarded-For`,
  `X-Real-Ip`, `X-Forwarded-Host` or `X-Forwarded-Proto` changes nothing:
  `nfltr up` drops them and sets its own.
- **The connection's peer** is `127.0.0.1` (the proxy).

## Run it

```
make reverse-proxy        # docker (Linux containers: iptables, tc), openssl
python3 reverse-proxy/test/results.py readme <run>/results.json
```

`RP_EXAMPLE_OUT` names the evidence directory (default: a new directory
under `$TMPDIR`, so the docker host sees the same path): per arm the visitor's JSON per
check, the bench, the port scan, the server's `/proc/net/tcp`, the
router's rules and every container's log, then `checks.jsonl` (every
check's exit code) and `results.json`.
`RP_PROXIES` runs a subset (`traefik`). A run takes about a minute after
the images are pulled.

The machines (`test/compose.yaml`): `server` (the home server, out only
through the router), `router` (NAT out, 10 ms each way between home and
the internet), `visitor` (on the internet) and `relay` (a private relay
standing in for the hosted one). A self-signed certificate for
`*.share.test` stands in for the one the hosted relay's agent gets from
Let's Encrypt; the visitor trusts it.

Per arm (Caddy and Traefik): routing by host and by path; the login (none
and a wrong password get 401, the right one reaches admin with
`X-Auth-User`); what the services see of a GET, with and without forged
headers; a WebSocket (upgrade, then 100 echoes); a link with a guessed
name refused; 200 kept-alive GETs; which ports of the home's public
address answer, what the server listens on, the router's rules; `nfltr
up` killed and started, timed until the app answers again through the
same link. Then the proxy's trust line is removed and what the services
see then is recorded.

## Results

<!-- rp:results -->
| check | caddy | traefik |
|---|---|---|
| app. host: / reaches the photos service | pass | pass |
| app. host: /api/ reaches the api service (path route) | pass | pass |
| admin. host reaches the admin service with the login, and it gets X-Auth-User from the proxy | pass | pass |
| admin. host without a login: 401 from the proxy | pass | pass |
| admin. host with a wrong password: 401 from the proxy | pass | pass |
| the service's view of the request (table below) | pass | pass |
| the service's view when the visitor forges X-Forwarded-For, X-Real-Ip, X-Forwarded-Host and -Proto | pass | pass |
| the admin service's view of the request | pass | pass |
| a WebSocket through the proxy: upgrade, then 100 echoes | pass | pass |
| a link with a guessed name is refused | pass | pass |
| the service can tell the visitor's address (X-Forwarded-For) and that it came over https | pass | pass |
| a forged X-Forwarded-For does not become the address the service reads first | pass | pass |
| nothing open on the home's public address, no inbound rule, nothing on the server listening beyond loopback | pass | pass |

What the photos service saw of one GET (`visitor` is the visitor's own address, 10.234.2.30 here; `loopback` is 127.0.0.1):

| header | caddy | traefik | caddy, no trust line | traefik, no trust line |
|---|---|---|---|---|
| connection from | `loopback` | `loopback` | `loopback` | `loopback` |
| Host | `app.home.arpa` | `app.home.arpa` | `app.home.arpa` | `app.home.arpa` |
| X-Forwarded-For | `visitor, loopback` | `visitor, loopback` | `loopback` | `loopback` |
| X-Real-Ip | `visitor` | `visitor` | `visitor` | `loopback` |
| X-Forwarded-Proto | `https` | `https` | `http` | `http` |
| X-Forwarded-Host | `the link's name` | `the link's name` | `app.home.arpa` | `app.home.arpa` |
| Via | `1.1 Caddy` | (none) | `1.1 Caddy` | (none) |

The same GET with forged headers (`X-Forwarded-For` and `X-Real-Ip` 203.0.113.9, `X-Forwarded-Host` evil.example, `X-Forwarded-Proto` http):

| header | caddy | traefik |
|---|---|---|
| X-Forwarded-For | `visitor, loopback` | `visitor, loopback` |
| X-Real-Ip | `visitor` | `visitor` |
| X-Forwarded-Proto | `https` | `https` |
| X-Forwarded-Host | `the link's name` | `the link's name` |

| arm | GET p50 / p95 (ms, n=200, kept alive) | WebSocket echo p50 / p95 (ms, n=100) | WebSocket open (ms, new connection) | answering again after a kill and start of |
|---|---|---|---|---|
| caddy | 21.4 / 23.9 | 20.8 / 22.2 | 49 | 0.8 s (agent) |
| traefik | 21.4 / 24.5 | 20.8 / 22.6 | 50 | 1.3 s (agent) |

| arm | lines of configuration | moving parts |
|---|---|---|
| caddy | 27 (`deploy/nfltr.yaml` 3, `deploy/hosts` 1, `deploy/caddy/Caddyfile` 23) | 3: nfltr up, running (a machine certificate from nfltr config login); the home names in /etc/hosts; the proxy, on loopback only |
| traefik | 32 (`deploy/nfltr.yaml` 3, `deploy/hosts` 1, `deploy/traefik/traefik.yml` 6, `deploy/traefik/dynamic/routes.yml` 22) | 3: nfltr up, running (a machine certificate from nfltr config login); the home names in /etc/hosts; the proxy, on loopback only |

From one run (43 s wall time).
<!-- /rp:results -->

Most of the latency is the 20 ms round trip through the home router. The
relay here sits next to the visitor; a relay far from both adds its
distance to every request.
