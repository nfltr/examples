#!/usr/bin/env bash
set -euo pipefail

# ── test-camera-stream.sh ───────────────────────────────────────────
# End-to-end test of camera-stream (README.md there): an RTSP camera on
# machine A (MediaMTX on A's loopback, fed an H.264 test pattern by
# ffmpeg), served under an nf1 address as agent camera-box; machine B,
# which has no account, forwards it to its own 127.0.0.1:18554 with nfltr
# cat forward --address-file and plays it with ffmpeg's tools over RTSP's
# TCP connection. Machines and relay: scripts/lib/nf1.sh.
# Judged by exit codes: ffprobe on B reads one H.264 stream, 640x360;
# ffmpeg on B saves a frame of it.
# CAMERA_STREAM_OUT: the evidence directory (default: a new temp dir).
# ─────────────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}"
# shellcheck source=lib/release.sh
. scripts/lib/release.sh
# shellcheck source=lib/enrol.sh
. scripts/lib/enrol.sh
# shellcheck source=lib/nf1.sh
. scripts/lib/nf1.sh
nf1_init camera-stream CAMERA_STREAM_OUT
NF1_SERVICES=(camera)
nf1_up
nf1_serve camera
nf1_forward
nf1_wait_listen

URL=rtsp://127.0.0.1:18554/stream
probe_b() {
	dc exec -T machine-b ffprobe -v error -rtsp_transport tcp -select_streams v:0 \
		-show_entries stream=codec_name,width,height -of csv=p=0 "${URL}"
}
say "the camera streaming on A, through the address"
for _ in $(seq 60); do
	probe_b >/dev/null 2>&1 && break
	sleep 1
done
say "B's player at ${URL}"
stream() { probe_b | tee "${T}/stream.txt" | grep -qx 'h264,640,360'; }
check h264-640x360 stream
frame() {
	dc exec -T machine-b ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i "${URL}" -frames:v 1 -y /run/nf1/frame.png &&
		dc exec -T machine-b test -s /run/nf1/frame.png
}
check frame frame
nf1_judge
