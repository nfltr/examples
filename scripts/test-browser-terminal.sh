#!/usr/bin/env bash
set -euo pipefail

# ── test-browser-terminal.sh ────────────────────────────────────────
# End-to-end test of browser-terminal (README.md there): a tmux session
# on machine A behind ttyd (its own user and password, on A's loopback
# only), served under an nf1 address; machine B, which has no account,
# forwards it to its own 127.0.0.1:7681 with nfltr cat forward
# --address-file, and B's browser (test/probe: ttyd's page and websocket)
# uses it. Machines and relay: scripts/lib/nf1.sh.
# Judged by exit codes: ttyd answers 401 without its password and with a
# wrong one, 200 with it; a command typed through the websocket runs in
# A's tmux session; after A serves again with --new-address the old
# address reaches nothing and the new one reaches ttyd.
# BROWSER_TERMINAL_OUT: the evidence directory (default: a new temp dir).
# ─────────────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}"
# shellcheck source=lib/release.sh
. scripts/lib/release.sh
# shellcheck source=lib/enrol.sh
. scripts/lib/enrol.sh
# shellcheck source=lib/nf1.sh
. scripts/lib/nf1.sh
nf1_init browser-terminal BROWSER_TERMINAL_OUT
PASS="$(openssl rand -hex 12)"
export TTYD_CREDENTIAL="you:${PASS}"
NF1_SERVICES=(terminal)
nf1_up
nf1_serve terminal
nf1_forward
nf1_wait_listen

browser() { dc exec -T machine-b /opt/nf1/probe "$@"; }
U=http://127.0.0.1:7681
say "B's browser at ${U}: ttyd's password is the second lock"
check no-password browser http -url "${U}" -want 401
check wrong-password browser http -url "${U}" -user you -pass wrong -want 401
check password browser http -url "${U}" -user you -pass "${PASS}" -want 200
MARKER="typed-on-b-$(openssl rand -hex 4)"
UPPER="$(printf '%s' "${MARKER}" | tr a-z A-Z)"
check typed browser type -url "${U}" -user you -pass "${PASS}" -marker "${MARKER}"
in_tmux() { dc exec -T terminal tmux capture-pane -p -t main | grep -qx "${UPPER}"; }
check in-tmux-on-a in_tmux

nf1_new_address
check old-address-ends refused browser http -url "${U}" -user you -pass "${PASS}" -want 200
old_refused() { dc logs --no-log-prefix b 2>&1 | grep 'no nf1 service at this address'; }
check old-address-refused old_refused
nf1_copy_address
nf1_forward
nf1_wait_listen
check new-address browser http -url "${U}" -user you -pass "${PASS}" -want 200
nf1_judge
