#!/usr/bin/env bash
set -euo pipefail

# ── test-device-gateway.sh ──────────────────────────────────────────
# End-to-end test of device-gateway (README.md there): a small
# device on a LAN (device/main.go: HTTP, a raw TCP socket, a UDP socket and
# an unpublished maintenance port; no nfltr on it), a gateway on the same
# LAN running nfltr up (gateway/gateway.yaml: one service per device port,
# end to end encrypted to the gateway for group ops, and the web UI under a
# capability address), a private relay, and a client outside the LAN with
# no route to it. Every machine is a container (test/compose.yaml) on
# networks with no internet.
# Judged by exit codes: the client reaches the device's HTTP, TCP and UDP
# ports by name, and its web UI over the nf1 address with no account; an
# unpublished port, a machine outside the group and a machine without a
# certificate are refused; the device's restart and the gateway's restart
# are recovered from with no action. Each check is a line of
# ${T}/checks.jsonl, judged into ${T}/results.json.
# DG_EXAMPLE_OUT: the evidence directory (default: a new temp dir).
# ─────────────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}"
# shellcheck source=lib/release.sh
. scripts/lib/release.sh
EX=device-gateway
T="${DG_EXAMPLE_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/device-gateway.XXXXXX")}"
mkdir -p "${T}"
T="$(cd "${T}" && pwd -P)"
export COMPOSE_PROJECT_NAME="device-gateway-$$"
export DG_IMAGE="nfltr-device-gateway:$$" DG_BIN="${T}/bin" DG_RUN="${T}/run" RELAY_PIN=""
# shellcheck source=lib/org.sh
. scripts/lib/org.sh
# shellcheck source=lib/enrol.sh
. scripts/lib/enrol.sh
say() { echo "── $*"; }
fail() { # the evidence directory stays on the machine that ran it: the last log lines go to the output too
    echo "FAIL: $* (evidence ${T})" >&2
    dc logs --no-color --tail 15 2>&1 | sed 's/nf1[a-z0-9]*/<address>/g' >&2 || true
    exit 1
}
dc() { docker compose -f "${EX}/test/compose.yaml" "$@"; }
ADDR=""
cleanup() {
    dc logs --no-color --timestamps >"${T}/compose.log" 2>&1 || true
    if [[ -n "${ADDR}" ]]; then # the address is a secret: kept out of the evidence
        sed "s/${ADDR}/<address>/g" "${T}/compose.log" >"${T}/compose.log.tmp" && mv "${T}/compose.log.tmp" "${T}/compose.log"
    fi
    dc down -v --remove-orphans -t 1 >/dev/null 2>&1 || true
    docker image rm "${DG_IMAGE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
check() { # name, then a command: its exit code is the check
    local name="$1" rc=0
    shift
    "$@" >>"${T}/checks.log" 2>&1 || rc=$?
    echo "{\"check\":\"${name}\",\"exit\":${rc}}" >>"${T}/checks.jsonl"
    echo "   ${name}: exit ${rc}"
}
expect() { # want, then a command: exit 0 when the command exits with want
    local want="$1" rc=0
    shift
    "$@" || rc=$?
    echo "exit ${rc}, want ${want}: $*"
    [[ "${rc}" == "${want}" ]]
}
not() { ! "$@"; }
recovers() { # name, then a command: retried each second for 90 s; the seconds it took into timings.jsonl
    local name="$1" t0
    shift
    t0="$(date +%s)"
    while (($(date +%s) - t0 < 90)); do
        if "$@" >>"${T}/checks.log" 2>&1; then
            echo "{\"timing\":\"${name}\",\"s\":$(($(date +%s) - t0))}" >>"${T}/timings.jsonl"
            return 0
        fi
        sleep 1
    done
    return 1
}
cfg() { echo "NFLTR_CONFIG=/run/dg/$1/nfltr.json"; } # the client's config of that machine
dial() { # config service: one nfltr cat pipe session from the client, stdin closed
    dc exec -T -e "$(cfg "$1")" client timeout 30 /opt/dg/nfltr cat pipe "gw.plant/$2" --server relay:8444 --open-timeout 10s </dev/null
}
get_ui() { # config: the device's web UI through gw.plant/ui
    dc exec -T -e "$(cfg "$1")" client sh -c 'set -o pipefail; printf "GET / HTTP/1.0\r\nHost: device\r\n\r\n" |
        timeout 30 /opt/dg/nfltr cat pipe gw.plant/ui --server relay:8444 --open-timeout 10s | grep -q esp32-demo'
}
echo_sensor() { # the device's raw TCP socket through gw.plant/sensor: one line, echoed
    dc exec -T client sh -c 'set -o pipefail; echo "reading 42" |
        timeout 30 /opt/dg/nfltr cat pipe gw.plant/sensor --server relay:8444 --open-timeout 10s | grep -qx "reading 42"'
}
get_ui_address() { # config: the web UI over the nf1 address (gw.plant/ui-link)
    dc exec -T -e "$(cfg "$1")" client sh -c 'set -o pipefail; printf "GET / HTTP/1.0\r\nHost: device\r\n\r\n" |
        timeout 30 /opt/dg/nfltr cat pipe --address-file /run/dg/ui.addr --server relay:8444 --open-timeout 10s | grep -q esp32-demo'
}
udp_coap() { dc exec -T client timeout 30 /opt/dg/device udp 127.0.0.1:5683 "coap-ping"; } # through cat forward --udp's listener
org_owner() { # the owner's nfltr, in the relay's container (scripts/lib/org.sh)
    dc exec -T -e PATH=/opt/dg:/usr/sbin:/usr/bin:/sbin:/bin -e NFLTR_CONFIG=/tmp/owner/nfltr.json \
        -e NFLTR_SERVER=127.0.0.1:8443 -e HTTP_SERVER_ADDR=https://127.0.0.1:8444 -e RPC_TLS=true \
        -e NFLTR_RELAY_CERT_SHA256="${RELAY_PIN}" relay "$@"
}
# Each machine enrols at the relay with a single-use code into its own
# config, named as it joins the organisation (scripts/lib/enrol.sh).
enrol_codegen() { dc exec -T relay /opt/dg/nfltr-relay machines code --data-dir /var/lib/relay "$@"; }
setrelay() { # service machine [dir]: config /run/dg[/dir]/nfltr.json
    enrol "$2" dc run --rm -T --no-deps ${3:+-e NFLTR_CONFIG=/run/dg/$3/nfltr.json} "$1" \
        /opt/dg/nfltr config set-relay relay:8443 --proxy-url https://relay:8444 --cert-sha256 "${RELAY_PIN}" --code-file -
}
join() { # service name group [dir]: a token from the owner, redeemed on that machine
    org_token "$2" "$3" | dc run --rm -T --no-deps ${4:+-e NFLTR_CONFIG=/run/dg/$4/nfltr.json} "$1" \
        /opt/dg/nfltr org join --root "${ORG_ROOT}" --recovery "${ORG_REC}" --token-file - >>"${T}/enrol.log" 2>&1
}

arch="$(docker version --format '{{.Server.Arch}}')"
say "nfltr, nfltr-relay and the device stand-in for linux/${arch} (released)"
mkdir -p "${DG_BIN}" "${DG_RUN}/gateway" "${DG_RUN}/client/ops" "${DG_RUN}/client/eve" "${DG_RUN}/client/none"
export CGO_ENABLED=0 GOOS=linux GOARCH="${arch}"
release_bins "${DG_BIN}" "${arch}" || fail "released nfltr and nfltr-relay"
go build -o "${DG_BIN}/device" "./${EX}/device"
unset CGO_ENABLED GOOS GOARCH
docker build -q -t "${DG_IMAGE}" "${EX}/test" >/dev/null || fail "docker build"
: >"${T}/checks.jsonl"
: >"${T}/timings.jsonl"
started="$(date +%s)"

say "the device, the relay; each machine enrolled; the organisation (groups devices, ops, guest)"
dc up -d device relay >/dev/null 2>&1 || fail "compose up"
for _ in $(seq 60); do
    RELAY_PIN="$(dc logs --no-log-prefix relay 2>&1 | sed -n 's/^TLS certificate SHA-256: //p' | head -1)"
    [[ -n "${RELAY_PIN}" ]] && break
    sleep 1
done
[[ "${RELAY_PIN}" =~ ^[0-9a-f]{64}$ ]] || fail "no certificate fingerprint in the relay log"
# The owner is the relay's first machine, admin (its code: the data dir's
# admin-enrol-code); the others join admin's account.
for _ in $(seq 30); do
    dc exec -T relay test -s /var/lib/relay/admin-enrol-code 2>/dev/null && break
    sleep 1
done
dc exec -T relay mkdir -p /tmp/owner &&
    dc exec -T relay cat /var/lib/relay/admin-enrol-code | dc exec -T -e NFLTR_CONFIG=/tmp/owner/nfltr.json relay \
        /opt/dg/nfltr config set-relay 127.0.0.1:8443 --proxy-url https://127.0.0.1:8444 --cert-sha256 "${RELAY_PIN}" --code-file - >/dev/null &&
    setrelay gateway gw && setrelay client ops ops && setrelay client eve eve ||
    fail "a machine did not enrol at the relay"
org_init devices,ops,guest /tmp/owner/recovery.key || fail "nfltr org init"
org_serve || fail "nfltr org serve"
join gateway gw devices && join client ops ops ops && join client eve guest eve || fail "nfltr org join"

say "the gateway: nfltr up -c gateway.yaml; the client: nfltr cat forward --udp for coap"
dc up -d gateway client >/dev/null 2>&1 || fail "compose up gateway client"
recovers first-session get_ui ops || fail "the client never reached the device's web UI"
ADDR="$(dc exec -T gateway head -1 /run/dg/nf1/plant.ui-link.key | tr -d '\r')"
[[ "${ADDR}" == nf1* ]] || fail "no address for plant/ui-link"
printf '%s\n' "${ADDR}" | dc exec -T client sh -c 'umask 077 && cat >/run/dg/ui.addr' # --address-file: never on argv
dc exec -d -T client sh -c 'exec /opt/dg/nfltr cat forward --udp gw.plant/coap --listen udp:127.0.0.1:5683 --server relay:8444 >/tmp/udp.log 2>&1'
recovers udp-forward udp_coap || true

say "checks"
check "ops reaches the device's web UI (HTTP, port 80) by name" get_ui ops
check "ops reaches the device's raw TCP socket (port 7)" echo_sensor
check "ops reaches the device's UDP socket (port 5683) through cat forward --udp" udp_coap
check "a machine with no account reaches the web UI over the nf1 address" get_ui_address none
check "the same machine by name, with no certificate, is refused" expect 2 dial none ui
check "the device's maintenance port (23) is not published" expect 3 dial ops maint
check "a machine of group guest is refused" expect 10 dial eve ui

say "the device restarts (a reboot or a power cut)"
dc stop -t 0 device >/dev/null 2>&1
check "while the device is down, the web UI does not answer" not get_ui ops
dc start device >/dev/null 2>&1
check "after the device restarts, the web UI answers with no action" recovers device-restart get_ui ops
check "after the device restarts, the raw TCP socket answers" echo_sensor

say "the gateway restarts"
dc restart -t 1 gateway >/dev/null 2>&1
check "after the gateway restarts, the web UI answers by name" recovers gateway-restart get_ui ops
check "after the gateway restarts, the nf1 address still opens the web UI" recovers gateway-restart-address get_ui_address none
check "after the gateway restarts, the UDP socket answers" recovers gateway-restart-udp udp_coap

say "results"
python3 - "${T}" "$(($(date +%s) - started))" <<'PY'
import json, sys
t, wall = sys.argv[1], int(sys.argv[2])
checks = [json.loads(l) for l in open(f"{t}/checks.jsonl")]
timings = {d["timing"]: d["s"] for d in map(json.loads, open(f"{t}/timings.jsonl"))}
res = {"pass": all(c["exit"] == 0 for c in checks), "wall_s": wall, "checks": checks, "recovery_s": timings}
json.dump(res, open(f"{t}/results.json", "w"), indent=2)
print(json.dumps(res, indent=2))
sys.exit(0 if res["pass"] else 1)
PY
echo "PASS: device-gateway example (evidence ${T})"
