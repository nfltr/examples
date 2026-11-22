# A UDP service for friends

A game server (or any UDP service) on machine A, joined from a friend's
machine B. nfltr carries UDP too: it serves the server's port under an nf1
address with `--udp`, and B needs the `nfltr` command and the address
file, no account. Each source address on B's side is a flow of its own
inside one encrypted session; the relay sees neither the address's secret
nor the datagrams. `make udp-service` runs it with a UDP echo server
standing in for a game server and judges every claim below by exit codes.

## Run it

On machine A, enrolled in your account (`nfltr config login`), with the
server on `127.0.0.1:27015`:

```console
a$ nfltr cat serve game --udp --forward 127.0.0.1:27015 --agent game-box --address --address-file game.addr
```

Copy `game.addr` to machine B over a channel you trust, then on B:

```console
b$ chmod 600 game.addr
b$ nfltr cat forward --udp --address-file game.addr --listen udp:127.0.0.1:27015
```

The friend's game joins the server at `127.0.0.1:27015`. A flow closes
after it has been idle a while (`--udp-idle`, 60 s by default). A game
server that uses TCP is served without `--udp`. The address lives in a
file of mode 0600 on both machines; `nfltr cat serve ... --new-address`
revokes it.

## What the test checks

`make udp-service` (`scripts/test-udp-service.sh`) runs machine A (a socat
UDP echo server on A's loopback, answering `server on A got: <datagram>`),
machine B and a private relay as containers; A and B share no network,
only the relay sits on both.

| Check | Passes when |
|---|---|
| `datagram-1` .. `datagram-3` | a datagram from B, each from a source port of its own, comes back with the server's answer |
| `no-route` | B cannot even resolve machine A: only the address reaches it |

Not run: a real game server; the echo server stands in for one.

| Path | What it is |
|---|---|
| `test/compose.yaml` | The echo server, `a` (the serve), `b` (the forward), on `scripts/lib/nf1/compose.yaml`'s machines and relay |
| `test/Dockerfile` | The machines' image: Alpine with socat |

`UDP_SERVICE_OUT` names the evidence directory (default: a new directory
under `$TMPDIR`): `checks.jsonl`, `checks.log`, `answers.txt` and the
containers' logs.
