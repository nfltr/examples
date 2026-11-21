# Adding nfltr to a .NET gRPC fleet

A control plane and many edge agents (.NET 8, often Windows behind NAT)
that exchange commands, progress and results over gRPC. `app/` is the
app as written: the control plane on a TLS port with a certificate from
a private CA, agents that trust that CA and keep the connection alive
through NATs. `with-nfltr/` is the same app with nfltr's connect sidecar
added. The protocol and the business logic are shared; `migration.patch`
is every change, and the end-to-end test runs both and checks they give
the same results. The changes for developers and for the organization,
with the numbers, the rollout and the limits: [MIGRATION.md](MIGRATION.md).

Two shapes:

- **(a) control plane -> agent by name** (with nfltr): each agent serves
  `Agent.Execute(Command) returns (stream Update)` on loopback; its sidecar
  publishes it as `<agent>/execute` (its machine named as the agent, so the
  control plane reaches `<agent>.<agent>/execute`); the control plane calls a chosen agent
  through a `connect:` mapping or one `nfltr cat pipe` per connection.
- **(b) agent-initiated session** (both): each agent opens
  `Fleet.Session(stream AgentMessage) returns (stream ControlMessage)` to the
  control plane; commands go down and progress and results come up on the
  one stream. In `app/` to the control plane's TLS endpoint; with nfltr
  through its sidecar's `connect:` mapping.

| Path | What it is |
|---|---|
| `proto/fleet.proto` | `Agent` (a) and `Fleet` (b), one `Command`/`Update` vocabulary |
| `common/` | The business logic, unchanged by the patch: the agent's work, `Agent.Execute`, the session loop with backoff; the control plane's session registry, dispatch and CLI |
| `app/` | The app as written: `agent/` (a worker service dialing the control plane), `controlplane/` (Kestrel on a TLS port, `appsettings.json`), `shared/ControlPlaneChannel.cs` (the TLS client: private CA, server name, keepalive) |
| `with-nfltr/` | The app with nfltr: the same projects on loopback, `shared/SidecarChannel.cs` (a `GrpcChannel` for a sidecar endpoint: `pipe:`, `unix:`, `host:port`), optional `DialChannel.cs`, `AgentChannels.cs`, `OwnedSidecar.cs`, `Job.cs`; `sidecar/` (the `nfltr up` files) |
| `migration.patch`, `migrate.sh` | `app/` -> `with-nfltr/`; `migrate.sh <dir>` applies it to a copy of `app/` and checks the result, `--update` regenerates it |
| `test/` | Dockerfile and compose files of the end-to-end test, its comparison and result scripts, `report.py` (writes the measured sections), `siteproxy/` (edge-2's site proxy) |

## Run it

On machines (nfltr with the connect sidecar, each machine enrolled with
`nfltr config login` (its machine named as its agent: a machine certificate),
the .NET 8 SDK; end-to-end encryption: MIGRATION.md "Organisation"):

```
# the control plane's machine
nfltr up -c with-nfltr/sidecar/controlplane.yaml &
dotnet run --project with-nfltr/controlplane -- serve
# each edge machine (or let the agent start its sidecar: --Sidecar edge-1.yaml)
nfltr up -c edge-1.yaml &
dotnet run --project with-nfltr/agent -- --Name edge-1
#   Windows: listen: "pipe:nfltr-fleet" in the file, --ControlPlane pipe:nfltr-fleet
# then, on the control plane's machine
dotnet run --project with-nfltr/controlplane -- dispatch --via mapping --agents edge-1,edge-2
dotnet run --project with-nfltr/controlplane -- dispatch --via session --agents edge-1,edge-2
```

`dispatch` prints one JSON line per agent and exits 0 when every agent's
outcome is `--expect` (default `ok`: the result and every progress update
arrived).

The end-to-end test, all in containers (no .NET or relay on the host):

```
make dotnet-fleet
```

It runs the released nfltr and nfltr-relay and checks by exit codes. In both
stacks `edge-2` is at a customer site whose only way out is the site's
HTTP proxy (`test/siteproxy`: CONNECT to an allow-list, 403 otherwise):
in `app/` the agent opens the CONNECT itself (`ControlPlane:Proxy`,
`app/shared/ControlPlaneChannel.cs`: grpc-dotnet's own connection logic
uses neither `HTTPS_PROXY` nor the handler's `Proxy`); with nfltr its
sidecar reads `HTTPS_PROXY`. Each stack checks that edge-2 has no direct
route and that the proxy refuses another target, and records what it let
through.

1. **`app/`**: issues the fleet's private CA and the control plane's
   certificate, runs the control plane on its TLS port and three
   agents dialing it; (b) with five streamed progress updates each; (a)
   refused (UNIMPLEMENTED: nothing reaches an agent); a 1 s deadline on a
   5 s command, cancelled on every agent; an agent killed mid-command:
   UNAVAILABLE, then the retry succeeds once it is back. Then latency over
   the direct TLS connection: the baseline.
2. **the patch**: `migrate.sh` applies `migration.patch` to a copy of
   `app/`; the result must equal `with-nfltr/`, and the with-nfltr images
   are built from it.
3. **`with-nfltr/`**: a private relay, the control plane and three agents
   (`edge-1` owns its sidecar; `edge-2` and `edge-3` run it beside the app;
   `edge-3`'s service is not end-to-end encrypted, the others are, in
   organisation mode: a throwaway organisation, every machine joined): (a)
   through mappings and through `nfltr cat pipe` and (b), five progress updates
   each; the deadline on both shapes; `edge-1` (agent and sidecar) and
   `edge-2`'s agent killed mid-command; `nfltr cat pipe` from a machine outside
   the allowed group exits 10 and a plain open of an end-to-end encrypted
   service exits 4. Then latency.
4. **the same results**: every agent's outcome, progress count and output
   are equal on (b) in `app/` and on (a) mapping, (a) dial and (b) with
   nfltr; the deadline outcomes and the retry after a restart too; and no
   fleet machine listens on anything but loopback with nfltr.

The evidence directory it prints has `results.json`. Run it after
changing this example. To refresh the numbers below and in
MIGRATION.md from one or more runs:

```
python3 dotnet-fleet/test/report.py <run>/results.json [<run 2>/results.json ...]
```

## Measured

One run of `make dotnet-fleet` on a Linux build machine (16 vCPU AMD
EPYC, Docker; shared with other work, load average about 17 to 20),
edge-2 behind its site's proxy in both stacks. The relay, the sidecars and
the programs share one host, so the with-nfltr rows are the sidecars' and
the relay's own overhead, not network latency, and the `app/` rows are the
same calls over a direct TLS connection between two containers: the
baseline. ms per call, p50 / p95, measured in the control plane around the
gRPC call. Each row: 100 calls (30 for new connections, 20 for 100
updates) after as many untimed ones; the result only unless it says
progress updates. A "new connection" is a new HTTP/2 connection: a new
sidecar session through the relay, plus the TLS 1.3 handshake with the
agent when end-to-end encrypted, plus a process start for `dial`.

<!-- BEGIN generated by test/report.py: measured -->
| call | transport | p50 / p95 |
|---|---|---|
| (b) session, direct TLS (`app/`, the baseline) | TLS to the control plane | 0.88 / 2.35 |
| (b) session | e2ee (control plane) | 0.79 / 1.40 |
| (a) mapping, warm channel | e2ee (edge-1) | 1.82 / 5.26 |
| (a) mapping, warm channel | plain (edge-3) | 1.84 / 6.06 |
| (a) mapping, new connection per call | e2ee (edge-1) | 5.86 / 25.07 |
| (a) mapping, new connection per call | plain (edge-3) | 3.79 / 15.84 |
| (a) `nfltr cat pipe`, warm channel | e2ee (edge-1) | 1.17 / 2.77 |
| (a) `nfltr cat pipe`, warm channel | plain (edge-3) | 1.07 / 3.28 |
| (a) `nfltr cat pipe`, new process per call | e2ee (edge-1) | 22.72 / 39.36 |
| (a) `nfltr cat pipe`, new process per call | plain (edge-3) | 14.04 / 23.72 |
| (b) session, 100 progress updates back to back, direct TLS (`app/`, the baseline) | TLS to the control plane | 2.60 / 3.81 |
| (b) session, 100 progress updates back to back | e2ee (control plane) | 1.96 / 6.56 |
| (a) mapping, 100 progress updates back to back | e2ee (edge-1) | 1.41 / 3.26 |

- **Overhead against the direct TLS connection**, p50 with nfltr minus p50 in `app/`, one run: a (b) session call -0.09 ms (two sidecars and the relay, E2EE on); with 100 progress updates back to back -0.64 ms (negative: faster with nfltr in that run).
- **Streaming**: a command doing 100 ms of work per step with 5 progress updates, both stacks, every path: the first update arrived 105.1 to 172.8 ms after the call, the result 505.8 to 576.7 ms after it: updates arrive as the agent sends them.
- **Agent restart** (killed mid-command, the control plane's own retry every 250 ms; ms after the kill, one run, Docker restarting the container included):

  | restart | UNAVAILABLE after | first ok call started after |
  |---|---|---|
  | `app/`: edge-2's agent, (b) over TLS | 120 | 1671 |
  | with nfltr: edge-2's agent (its sidecar kept running), (b) | 122 | 1419 |
  | with nfltr: edge-1's agent and the sidecar it owns, (a) mapping | 33181 | 33468 |
<!-- END generated: measured -->

edge-1's agent and the sidecar it owns die together when the container is
killed; in this run the control plane's (a) calls to it saw UNAVAILABLE
about 33 s after the kill, and the first ok call followed about 0.3 s
later. edge-2's agent alone, its sidecar running, failed at once.

What each stack runs on the fleet's machines, from the same run (MIGRATION.md has the
diff):

<!-- BEGIN generated by test/report.py: moving-parts -->
| | the app on its own network setup (`app/`) | the app with nfltr (`with-nfltr/`) |
|---|---|---|
| TCP listeners on the fleet's machines that are not loopback | 1 (controlplane 0.0.0.0:8443) | 0 |
| private CA (its key kept off the fleet) and the certificates it issued | 1 CA, 1 certificate | none |
| machine certificate from the relay on every machine (nfltr renews it) | no | yes |
| processes on the fleet's 4 machines (apps + sidecars) | 4 + 0 | 4 + 4 |
| what edge-2's site proxy let through: CONNECT to | `controlplane.fleet.example:8443` | `relay:8443`, `relay:8444` |
| the control plane calls an agent by name (a) | no (UNIMPLEMENTED, checked) | yes, by mapping or `nfltr cat pipe` |
| `docker compose up` to the first ok command on every agent, one run (with nfltr: the relay already up) | 3183 ms | 3596 ms |

Listeners: read from `/proc/net/tcp` and `/proc/net/tcp6` of each fleet machine while it ran (with nfltr, the machines include their sidecars). The relay is not a fleet machine and is not counted: hosted, it is not the organization's to run; on the organization's own relay, it is one public endpoint for every fleet of the account.
<!-- END generated: moving-parts -->
