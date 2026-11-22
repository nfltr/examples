#!/usr/bin/env bash
set -euo pipefail

# ── test-shared-database.sh ─────────────────────────────────────────
# End-to-end test of shared-database (README.md there): Postgres on
# machine A's loopback, served under an nf1 address as agent db-box;
# a colleague's machine B, which has no account, forwards it to its own
# 127.0.0.1:15432 with nfltr cat forward --address-file and runs psql.
# Machines and relay: scripts/lib/nf1.sh.
# Judged by exit codes: psql through the address reads the server's
# version and a row; Postgres still refuses a wrong password.
# SHARED_DATABASE_OUT: the evidence directory (default: a new temp dir).
# ─────────────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}"
# shellcheck source=lib/release.sh
. scripts/lib/release.sh
# shellcheck source=lib/enrol.sh
. scripts/lib/enrol.sh
# shellcheck source=lib/nf1.sh
. scripts/lib/nf1.sh
nf1_init shared-database SHARED_DATABASE_OUT
PGPASSWORD="$(openssl rand -hex 12)"
export PGPASSWORD
NF1_SERVICES=(postgres)
nf1_up
nf1_serve db
nf1_forward
nf1_wait_listen

psql_b() { # PASSWORD SQL: psql on B, through the address
	dc exec -T -e PGPASSWORD="$1" machine-b psql -h 127.0.0.1 -p 15432 -U postgres -tAc "$2"
}
say "Postgres ready on A, through the address"
for _ in $(seq 60); do
	psql_b "${PGPASSWORD}" "select 1" >/dev/null 2>&1 && break
	sleep 1
done
say "the colleague's psql on B"
greeting() { psql_b "${PGPASSWORD}" "select 'hello from machine A'" | grep -qx 'hello from machine A'; }
check greeting greeting
version() { psql_b "${PGPASSWORD}" "show server_version" | grep -q '^17\.'; }
check server-version version
check wrong-password refused psql_b wrong "select 1"
nf1_judge
