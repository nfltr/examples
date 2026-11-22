#!/usr/bin/env bash
set -euo pipefail

# ── test-remote-desktop.sh ──────────────────────────────────────────
# End-to-end test of remote-desktop (README.md there): a Linux desktop
# on machine A (Xvfb, an xterm, x11vnc on A's loopback only), served under
# an nf1 address as agent desk; machine B, which has no account, forwards
# it to its own 127.0.0.1:15900 with nfltr cat forward --address-file,
# where a VNC viewer (test/probe) connects. Machines and relay:
# scripts/lib/nf1.sh.
# Judged by exit codes: with the VNC password the viewer completes the
# handshake, reads the desktop's size and name and a full frame; with a
# wrong password the server refuses it.
# REMOTE_DESKTOP_OUT: the evidence directory (default: a new temp dir).
# ─────────────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}"
# shellcheck source=lib/release.sh
. scripts/lib/release.sh
# shellcheck source=lib/enrol.sh
. scripts/lib/enrol.sh
# shellcheck source=lib/nf1.sh
. scripts/lib/nf1.sh
nf1_init remote-desktop REMOTE_DESKTOP_OUT
VNC_PASSWORD="$(openssl rand -hex 4)" # VNC authentication uses 8 characters
export VNC_PASSWORD
NF1_SERVICES=(desktop)
nf1_up
nf1_serve desktop
nf1_forward
nf1_wait_listen

viewer() { dc exec -T machine-b /opt/nf1/probe -addr 127.0.0.1:15900 "$@"; }
say "the desktop ready on A, through the address"
for _ in $(seq 60); do
	viewer -pass "${VNC_PASSWORD}" >/dev/null 2>&1 && break
	sleep 1
done
say "B's VNC viewer at 127.0.0.1:15900"
frame() { viewer -pass "${VNC_PASSWORD}" | tee "${T}/desktop.json" | grep -q '"Width":1024,"Height":640,"Name":"machine A","frame_bytes":2621440'; }
check full-frame frame
check wrong-password refused viewer -pass wrong
nf1_judge
