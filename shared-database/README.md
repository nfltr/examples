# A database for a colleague

A Postgres on machine A, used with `psql` from a colleague's machine B.
nfltr serves Postgres's port under an nf1 address: B needs the `nfltr`
command and the address file, no account, and Postgres listens on A's
loopback only. The session is end to end encrypted between the two
machines; the relay sees neither the address's secret nor the queries.
`make shared-database` runs it with the official Postgres image and judges
every claim below by exit codes.

## Run it

On machine A, enrolled in your account (`nfltr config login`):

```console
a$ nfltr cat serve db --forward 127.0.0.1:5432 --agent db-box --address --address-file db.addr
```

`--agent db-box` gives the service its own agent name, so the machine can
serve other things under its default one. Copy `db.addr` to machine B over
a channel you trust, then on B:

```console
b$ chmod 600 db.addr
b$ nfltr cat forward --address-file db.addr --listen 127.0.0.1:15432
b$ psql -h 127.0.0.1 -p 15432 -U postgres -c "select 'hello from machine A' as greeting;"
```

## Postgres's own password

`nfltr cat serve` on A connects to Postgres from `127.0.0.1` for every
address holder, so make Postgres ask a password of loopback TCP
connections. The official image (and many packaged setups) trusts
loopback by default; `postgres/pg_hba.conf` asks every TCP client for a
password:

```
local   all       all                 trust
host    all       all   127.0.0.1/32  scram-sha-256
host    all       all   ::1/128       scram-sha-256
```

The address then gets the colleague to Postgres's login, and Postgres's
users tell people apart. The address lives in a file of mode 0600 on both
machines; `nfltr cat serve ... --new-address` revokes it.

## What the test checks

`make shared-database` (`scripts/test-shared-database.sh`) runs machine A
(Postgres 17, the official image by digest, on A's loopback with
`postgres/pg_hba.conf` and a password random per run), machine B and a
private relay as containers; A and B share no network, only the relay sits
on both.

| Check | Passes when |
|---|---|
| `greeting` | psql on B through the address reads the row `hello from machine A` |
| `server-version` | it reads the server's version, 17 |
| `wrong-password` | Postgres refuses a wrong password through the address |

| Path | What it is |
|---|---|
| `postgres/pg_hba.conf` | Who Postgres lets in: a password for every TCP client |
| `test/compose.yaml` | Postgres, `a` (the serve), `b` (the forward), on `scripts/lib/nf1/compose.yaml`'s machines and relay |
| `test/Dockerfile` | The machines' image: Alpine with psql |

`SHARED_DATABASE_OUT` names the evidence directory (default: a new
directory under `$TMPDIR`): `checks.jsonl`, `checks.log` and the
containers' logs.
