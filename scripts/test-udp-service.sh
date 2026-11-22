#!/usr/bin/env bash
set -euo pipefail

# ── test-udp-service.sh ─────────────────────────────────────────────
# End-to-end test of udp-service (README.md there): a UDP service on
# machine A's loopback (an echo server standing in for a game server),
# served under an nf1 address (nfltr cat serve --udp --address), reached
# from machine B, which has no account, with nfltr cat forward --udp
# --address-file. Machines and relay: scripts/lib/nf1.sh.
# Judged by exit codes: three datagrams from three source ports on B
# answered by the server on A; nothing on A's network answers B directly.
# UDP_SERVICE_OUT: the evidence directory (default: a new temp dir).
# ─────────────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}"
# shellcheck source=lib/release.sh
. scripts/lib/release.sh
# shellcheck source=lib/enrol.sh
. scripts/lib/enrol.sh
# shellcheck source=lib/nf1.sh
. scripts/lib/nf1.sh
nf1_init udp-service UDP_SERVICE_OUT
NF1_SERVICES=(echo)
nf1_up
nf1_serve game
nf1_forward
nf1_wait_listen

say "B's game client: datagrams to 127.0.0.1:27015, answered by the server on A"
datagram() { # N: one datagram from a source port of its own; its answer
	dc exec -T machine-b sh -c "printf 'ping $1\n' | socat -t5 - UDP4:127.0.0.1:27015" | tee -a "${T}/answers.txt" |
		grep -qx "server on A got: ping $1"
}
for n in 1 2 3; do check "datagram-${n}" datagram "${n}"; done
say "B has no route to A: only the address reaches the service"
check no-route refused dc exec -T machine-b sh -c "getent hosts machine-a"
nf1_judge
