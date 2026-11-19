# Your GPU box, reachable from anywhere

A machine at home or in the office runs a local model server (an
OpenAI-compatible HTTP API, as Ollama and vLLM serve it), and a laptop
elsewhere uses it. `make gpu-box` sets it up with nfltr in containers and
judges every claim below by exit codes. The tables are written from its
`results.json` by `test/results.py readme`.

`nfltr up` on the box dials out to a relay and publishes the model
server's loopback port (Ollama's default, `127.0.0.1:11434`) as
`gpu/model`, end-to-end encrypted in organisation mode (the relay carries
TLS records only): you make an organisation once (`nfltr org init`), both
machines join it (`nfltr org join`), and the service is served only to
machines of group `home` (`allow_group: [home]`). `nfltr up` on the laptop
maps `gpu.gpu/model` (agent `gpu` on machine `gpu`) to the laptop's own
`127.0.0.1:11434`, so any tool pointed at `http://127.0.0.1:11434/v1`
reaches the box. Nothing on the box listens beyond loopback, nothing is
open on the home's public address, and the router has no inbound rule.
`nfltr cat pipe gpu.gpu/model` opens one session on stdin/stdout, without
a mapping.

| Path | What it is |
|---|---|
| `model/` | The stand-in model server: `GET /v1/models` and `POST /v1/chat/completions` (with and without `stream`), token *i* is `w<i> `, one every 10 ms. No GPU or model needed |
| `client/` | The laptop's client: `wait`, `bench` (completion latency, time to first token, bytes), reading `OPENAI_BASE_URL` as OpenAI tools do |
| `deploy/` | `box.yaml`, `laptop.yaml` (the two `nfltr up` files), `relay.env` (this test's private relay; `nfltr config login` replaces it for the hosted one), `box.env`, `laptop.env` (the config holding each machine's relay certificate, enrolled with a single-use code as `nfltr config set-relay --code-file -`, and its organisation enrolment) |
| `test/` | The machines (`compose.yaml`: box, router, laptop, the relay), the image, `results.py` (judge, README tables) |

## A real model

Replace the stand-in with Ollama on the box; nothing else changes:

```
ollama serve            # listens on 127.0.0.1:11434, as the stand-in does
```

The laptop then uses any model the box has pulled, for example
`curl http://127.0.0.1:11434/v1/chat/completions -d '{"model":"llama3.2","messages":[...]}'`.
vLLM listens on port 8000 by default: change `tcp: 11434` in `box.yaml`
to match.

## Run it

```
make gpu-box                                  # docker (Linux containers: iptables, tc)
python3 gpu-box/test/results.py readme <run>/results.json
```

`GPU_BOX_OUT` names the evidence directory (default: a new directory
under `$TMPDIR`, so the docker host sees the same path): the binaries, the
provisioned files and container logs, `checks.jsonl` (every check's exit
code), each bench, each machine's `/proc/net/tcp`, the router's rules and
`results.json`.

The machines (`test/compose.yaml`): `box` (out only through the router; it
drops new connections from anywhere but the router, since the Docker host
would otherwise route to it), `router` (NAT out, 10 ms each way between
home and the outside), `laptop`, and `relay`, a private relay outside the
home (TLS self-signed, pinned).

In order: the model server measured on the box itself (the baseline);
each machine enrols at the relay and joins the organisation; `nfltr up`
on both machines; the laptop's first answer, 100 completions and 100
streamed answers (16 tokens each; one unmeasured call first opens the
connection); `nfltr cat pipe` from the laptop exits 0, from a machine
without a relay certificate 2, from a machine not enrolled in the
organisation 4 and from one outside the group 10; `nc -z` to the home's
public address on ports 443 and 11434 finds them closed; the listeners and
the router's rules; then the box's `nfltr up` killed and started, timed
until the laptop's next answer.

## Results

<!-- gb:results -->
| | completion p50 / p95 (ms) | first token p50 / p95 (ms) | streamed answer p50 (ms) |
|---|---|---|---|
| on the box | 164.3 / 167.9 | 10.7 / 11.4 | 166.5 |
| from the laptop, through nfltr | 185.8 / 191.0 | 31.7 / 35.8 | 188.3 |

| check | result |
|---|---|
| the machine's certificate opens a session | pass |
| a machine without a certificate is refused | pass |
| a machine not enrolled is refused | pass |
| a machine outside the group is refused | pass |
| the home's public address: port 443 closed | pass |
| the home's public address: port 11434 closed | pass |
| nothing on the box or the laptop listens beyond loopback | pass |
| no inbound rule on the router | pass |
| answered after nfltr up on the box restarted, within 120 s | pass |

After `nfltr up` on the box was killed and started, the laptop's next answer came 2306 ms later.

Through the relay, a streamed answer carries 198.2 bytes per token (OpenAI-style streaming sends one JSON chunk per token).
<!-- /gb:results -->

Through nfltr the first token comes about 21 ms later than on the box:
the home-to-outside round trip (10 ms each way). The relay here sits on
the laptop's side of that round trip; a relay far from both machines adds
its own distance to every answer.
