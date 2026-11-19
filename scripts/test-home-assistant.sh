#!/usr/bin/env bash
set -euo pipefail

# ── test-home-assistant.sh ──────────────────────────────────────────
# End-to-end test of home-assistant (README.md there): a real
# Home Assistant (the official image, pinned by digest) on a home network
# behind NAT, used from a visitor on the internet (the phone or laptop
# away from home), every machine a container (test/compose.yaml). nfltr up
# at home dials out to a relay and gives Home Assistant an unlisted,
# end-to-end encrypted HTTPS link; the router forwards nothing (nfltr/).
# The visitor (test/probe) checks the UI, the REST API, the WebSocket's
# live updates, refusals without a token, which ports of the home's public
# address accept a connection, then measures latency and bytes. Then the
# agent is killed and started, timed until Home Assistant answers through
# the same link again. test/report.py assembles results.json (exit 1 when
# a check failed) and writes README.md's tables.
# HA_EXAMPLE_OUT: the evidence directory (default: a new temp dir).
# ─────────────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}"
# shellcheck source=lib/release.sh
. scripts/lib/release.sh
# shellcheck source=lib/enrol.sh
. scripts/lib/enrol.sh
EX=home-assistant
T="${HA_EXAMPLE_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/ha-example.XXXXXX")}"
mkdir -p "${T}"
T="$(cd "${T}" && pwd -P)"
export COMPOSE_PROJECT_NAME="ha-example-$$"
export HA_IMAGE_LOCAL="nfltr-ha-example:$$" HA_BIN="${T}/bin" HA_RUN="${T}/run"
# Home Assistant 2026.10.4, by digest.
export HA_IMAGE="homeassistant/home-assistant:2026.10.4@sha256:23f4dfbb69ce76315dbc4de7915504f1c2dcecd7ca2648113a493a385972e133"
say() { echo "── $*"; }
fail() { echo "FAIL: $* (evidence ${T})" >&2; exit 1; }
dc() { docker compose -f "${EX}/test/compose.yaml" "$@"; }
cleanup() {
    dc logs --no-color --timestamps >"${T}/compose.log" 2>&1 || true
    dc down -v --remove-orphans -t 2 >/dev/null 2>&1 || true
    docker image rm "${HA_IMAGE_LOCAL}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
probe() { dc exec -T visitor /opt/ha/probe "$@"; }
fp() { openssl x509 -in "$1" -outform DER | openssl dgst -sha256 -r | cut -d' ' -f1; }
machines_up() {
    dc up -d router home visitor homeassistant >/dev/null 2>&1
    for _ in $(seq 30); do
        dc exec -T router test -e /tmp/ready 2>/dev/null && dc exec -T home test -e /tmp/ready 2>/dev/null && return 0
        sleep 1
    done
    fail "the machines never came up"
}
PORTS=80,443,8123,8443
exposure() { # which ports of the home's public address and of the home machine accept a connection
    probe ports -host 10.236.2.2 -ports "${PORTS}" >"${T}/ports-public.json" || fail "ports"
    probe ports -host 10.236.1.10 -ports "${PORTS}" >"${T}/ports-home.json" || fail "ports"
    dc exec -T router sh -c 'iptables -t nat -S PREROUTING; iptables -S FORWARD' >"${T}/router-rules.txt"
    cat "${T}/ports-public.json"
}

arch="$(docker version --format '{{.Server.Arch}}')"
say "nfltr, nfltr-relay and the probe for linux/${arch} (released)"
mkdir -p "${HA_BIN}" "${HA_RUN}/config" "${HA_RUN}/agent/home"
export CGO_ENABLED=0 GOOS=linux GOARCH="${arch}"
release_bins "${HA_BIN}" "${arch}" || fail "released nfltr and nfltr-relay"
go build -o "${HA_BIN}/probe" "./${EX}/test/probe"
unset CGO_ENABLED GOOS GOARCH
docker build -q -t "${HA_IMAGE_LOCAL}" "${EX}/test" >/dev/null || fail "docker build"
docker pull -q "${HA_IMAGE}" >/dev/null || fail "docker pull"
cp "${EX}/ha/configuration.yaml" "${HA_RUN}/config/"
started="$(date +%s)"

say "Home Assistant: first start and onboarding (the owner account, a token for the visitor)"
machines_up
ha_t0="$(date +%s)"
dc exec -T home /opt/ha/probe onboard -base http://127.0.0.1:8123 -token /run/ha/token >/dev/null || fail "onboarding"
echo "{\"ha_ready_s\":$(($(date +%s) - ha_t0))}" >"${T}/ha.json"

say "the relay (private, TLS self-signed)"
dc up -d relay >/dev/null 2>&1
RELAY_PIN=""
for _ in $(seq 60); do
    RELAY_PIN="$(dc logs --no-log-prefix relay 2>&1 | sed -n 's/^TLS certificate SHA-256: //p' | head -1)"
    [[ -n "${RELAY_PIN}" ]] && break
    sleep 1
done
[[ "${RELAY_PIN}" =~ ^[0-9a-f]{64}$ ]] || fail "no certificate fingerprint in the relay log"
export RELAY_PIN
# The agent's machine enrols with a single-use code into its own config
# (HOME): a certificate from the relay's machine CA, no API key.
enrol_codegen() { dc exec -T relay /opt/ha/nfltr-relay machines code --data-dir /var/lib/relay "$@"; }
enrol home dc run --rm -T --no-deps agent /opt/ha/nfltr config set-relay 10.236.2.10:8443 \
    --proxy-url https://10.236.2.10:8444 --cert-sha256 "${RELAY_PIN}" --code-file - || fail "the agent's machine did not enrol"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 7 -subj /CN=share.test \
    -addext subjectAltName=DNS:*.share.test -keyout "${HA_RUN}/agent/link.key" -out "${HA_RUN}/agent/link.crt" 2>/dev/null
chmod 600 "${HA_RUN}/agent/link.key"
say "nfltr up (nfltr/home.yaml)"
agent_t0="$(date +%s)"
dc up -d agent >/dev/null 2>&1
link_host() {
    dc logs --no-log-prefix agent 2>/dev/null | grep -o 'https://[a-z0-9-]*\.share\.test' | tail -1 | sed 's|https://||'
}
LINK=""
for _ in $(seq 60); do
    LINK="$(link_host)"
    [[ -n "${LINK}" ]] && break
    sleep 1
done
[[ -n "${LINK}" ]] || fail "no link in the agent's log"
A=(-base "https://${LINK}" -addr 10.236.2.10:8443 -pin "$(fp "${HA_RUN}/agent/link.crt")" -token /run/ha/token)
probe wait "${A[@]}" -timeout 60s >"${T}/first-answer.json" || fail "never answered"
echo "{\"agent_to_first_answer_s\":$(($(date +%s) - agent_t0))}" >"${T}/start.json"
probe check "${A[@]}" >"${T}/check.json" || { cat "${T}/check.json"; fail "check"; }
say "a visitor with another link (a guessed name) is refused"
if probe wait -base "https://aaaaaaaaaaaaaaaaaaaaaaaaaa.share.test" -addr 10.236.2.10:8443 \
    -pin "$(fp "${HA_RUN}/agent/link.crt")" -token /run/ha/token -timeout 5s >/dev/null 2>&1; then
    echo '{"pass":false}' >"${T}/guessed-link.json"
    fail "a guessed link reached Home Assistant"
fi
echo '{"pass":true}' >"${T}/guessed-link.json"
say "the relay sees no plaintext: the visitor's TLS is the link certificate's, not the relay's"
echo "{\"link_cert_sha256\":\"$(fp "${HA_RUN}/agent/link.crt")\",\"relay_cert_sha256\":\"${RELAY_PIN}\"}" >"${T}/certs.json"
probe bench "${A[@]}" -n 300 >"${T}/bench.json" || fail "bench"
exposure
say "the agent killed and started"
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
t_kill="$(ms)"
dc kill agent >/dev/null 2>&1
dc start agent >/dev/null 2>&1
t_started="$(ms)"
probe wait "${A[@]}" -timeout 120s >/dev/null || fail "no answer after the agent restart"
# from the kill (and from the agent's start) to Home Assistant answering through the link again
echo "{\"ms\":$(($(ms) - t_kill)),\"after_start_ms\":$(($(ms) - t_started))}" >"${T}/restart.json"
[[ "$(link_host)" == "${LINK}" ]] || fail "the link changed with the restart"
probe check "${A[@]}" >"${T}/check-after-restart.json" || fail "check after the restart"

say "results"
echo "{\"wall_s\":$(($(date +%s) - started))}" >"${T}/wall.json"
python3 "${EX}/test/report.py" judge "${T}" || fail "results"
echo "PASS: home-assistant example (evidence ${T})"
