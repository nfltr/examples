# A terminal in another computer's browser

A `tmux` session on machine A (a shell, or a long job such as a coding
agent running in it), opened in a browser on machine B. ttyd serves the
session as a web page on A's loopback only, with its own user name and
password, and nfltr serves that one port under an nf1 address: B needs
the `nfltr` command and the address file, no account. The session is end
to end encrypted between the two machines; the relay that introduces
them sees neither the address's secret nor the bytes. `make
browser-terminal` runs it in containers and judges every claim below by
exit codes.

## Run it

On machine A, enrolled in your account (`nfltr config login`):

```console
a$ tmux new -d -s main
a$ ttyd -W -i 127.0.0.1 -p 7681 -c you:a-long-passphrase tmux attach -t main
a$ nfltr cat serve terminal --forward 127.0.0.1:7681 --address --address-file terminal.addr
Address of you/terminal written to terminal.addr (mode 0600; anyone who has it can open the service; keep it secret)
```

`-i 127.0.0.1` keeps ttyd off the network, `-W` lets the browser type, and
`-c` sets the user and password ttyd asks for. Copy `terminal.addr` to
machine B over a channel you trust (a password manager's share, an
encrypted message), then on B:

```console
b$ chmod 600 terminal.addr
b$ nfltr cat forward --address-file terminal.addr --listen 127.0.0.1:7681
```

`http://127.0.0.1:7681` in B's browser asks for ttyd's password and shows
the session; `tmux attach -t main` on A shows what B types, and closing
the browser leaves the session running.

## Two locks, and revoking

The address is never printed and never on a command line: it lives in a
file of mode 0600 on both machines, and `nfltr cat forward` refuses one
that others can read. Whoever holds it reaches ttyd, so ttyd's password is
the second lock: without it the page answers 401. ttyd's password sits on
ttyd's command line, which other users of A can read.

To revoke the address, serve again with `--new-address`: the old address
reaches nothing from then on, and the file holds a new one for whoever
should still have it.

```console
a$ nfltr cat serve terminal --forward 127.0.0.1:7681 --address --address-file terminal.addr --new-address
```

## What the test checks

`make browser-terminal` (`scripts/test-browser-terminal.sh`) runs machine
A, machine B and a private relay as containers; A and B share no network,
only the relay sits on both. A's ttyd password is random per run. B's
browser is `test/probe`, which asks what ttyd's page asks: the page, its
token and its websocket.

| Check | Passes when |
|---|---|
| `no-password`, `wrong-password` | ttyd through the address answers 401 |
| `password` | it answers 200 |
| `typed` | `echo <marker> \| tr a-z A-Z`, typed through the websocket, shows the upper-cased marker |
| `in-tmux-on-a` | that output is in A's `tmux` pane |
| `old-address-ends`, `old-address-refused` | after `--new-address`, B's forward of the old address gets no page, and the relay answers `no nf1 service at this address` |
| `new-address` | a forward of the new address reaches ttyd again |

| Path | What it is |
|---|---|
| `test/compose.yaml` | The terminal (ttyd and tmux on A's loopback), `a` (the serve), `b` (the forward), on `scripts/lib/nf1/compose.yaml`'s machines and relay |
| `test/Dockerfile` | The machines' image: Alpine with ttyd and tmux |
| `test/probe/` | B's browser: `http` (a status), `type` (keystrokes through ttyd's websocket) |

`BROWSER_TERMINAL_OUT` names the evidence directory (default: a new
directory under `$TMPDIR`): `checks.jsonl` (every check's exit code),
`checks.log` and the containers' logs.
