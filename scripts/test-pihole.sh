#!/usr/bin/env bash
set -euo pipefail

# ── test-pihole.sh ──────────────────────────────────────────────────
# End-to-end test of pihole (README.md there): the home's
# Pi-hole (the official image) used as a laptop's resolver away from home,
# every machine a container (test/compose.yaml), 10 ms each way through
# the home router: nfltr up on the box (Pi-hole's DNS over TCP and its web
# interface as end-to-end encrypted tcp services) and on the laptop
# (connect: mappings, a CoreDNS stub turning the system's UDP queries into
# TCP), through a private relay outside.
# Judged by exit codes: an ad domain blocked and a normal domain answered
# through the path, the admin page reachable from the laptop and closed
# from outside, refusals, nothing answering DNS on the home's public
# address, recovery after the box's nfltr agent restarts, the listeners and
# the router's rules; query latency into bench*.json (and Pi-hole on the box
# itself, the baseline).
# test/results.py judges the run into ${T}/results.json (exit code).
# PIHOLE_OUT: the evidence directory (default: a new temp dir).
# ─────────────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}"
# shellcheck source=lib/release.sh
. scripts/lib/release.sh
EX=pihole
T="${PIHOLE_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/pihole.XXXXXX")}"
mkdir -p "${T}"
T="$(cd "${T}" && pwd -P)"
export COMPOSE_PROJECT_NAME="pihole-$$"
export PH_IMAGE="nfltr-pihole:$$" PH_BIN="${T}/bin"
PUBLIC_IP=10.233.2.2
# shellcheck source=lib/org.sh
. scripts/lib/org.sh
# shellcheck source=lib/enrol.sh
. scripts/lib/enrol.sh
say() { echo "── $*"; }
fail() { echo "FAIL: $* (evidence ${T})" >&2; exit 1; }
dc() { docker compose -f "${EX}/test/compose.yaml" "$@"; }
cleanup() {
    dc logs --no-color --timestamps >"${T}/compose.log" 2>&1 || true
    dc down -v --remove-orphans -t 1 >/dev/null 2>&1 || true
    docker image rm "${PH_IMAGE}" >/dev/null 2>&1 || true
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
    [[ "${rc}" == "${want}" ]]
}
# The laptop's DNS client with its resolver (deploy/laptop.env); flags override it.
client() {
    local envs=() line
    while IFS= read -r line; do envs+=(-e "${line}"); done < <(grep '^DNS_' "${EX}/deploy/laptop.env")
    dc exec -T "${envs[@]}" laptop /opt/ph/client "$@"
}
machines_up() {
    dc up -d router box laptop internet pihole >"${T}/machines-up.log" 2>&1 || { cat "${T}/machines-up.log" >&2; fail "the machines did not start"; }
    for _ in $(seq 30); do
        dc exec -T router test -e /tmp/ready 2>/dev/null && dc exec -T box test -e /tmp/ready 2>/dev/null && break
        sleep 1
    done
    # Pi-hole is ready when it blocks: gravity has read the blocklist.
    local ms
    ms="$(dc exec -T box /opt/ph/client wait -server 127.0.0.1:53 -name ads.doubleclick.net -want 0.0.0.0 -timeout 180s)" ||
        fail "Pi-hole never blocked"
    echo "   Pi-hole blocking after ${ms} ms"
}
public_closed() { # nothing on the home's public address answers DNS or the admin page
    check "no DNS answer on the home's public address (udp)" expect 1 client once -server "${PUBLIC_IP}:53" -net udp
    check "no DNS answer on the home's public address (tcp)" expect 1 client once -server "${PUBLIC_IP}:53" -net tcp
    check "the home's port 80 is closed" expect 1 dc exec -T laptop nc -z -w 3 "${PUBLIC_IP}" 80
    check "the home's port 443 is closed" expect 1 dc exec -T laptop nc -z -w 3 "${PUBLIC_IP}" 443
}
blocking() {
    check "an ad domain is blocked" client once -name ads.doubleclick.net -want 0.0.0.0
    check "a tracker domain is blocked" client once -name tracker.example-ads.net -want 0.0.0.0
    check "a normal domain resolves" client once -name www.example.com -want 192.0.2.10
}
inventory() { # the box's and laptop's listeners, the router's rules
    local m
    for m in box laptop; do
        dc exec -T "${m}" cat /proc/net/tcp /proc/net/tcp6 >"${T}/tcp-${m}.txt"
        dc exec -T "${m}" cat /proc/net/udp /proc/net/udp6 >"${T}/udp-${m}.txt"
    done
    dc exec -T router sh -c 'iptables -t nat -S; iptables -S' >"${T}/router-rules.txt"
}
restart() { # service: kill and start it, then ms until the laptop's next answer
    dc kill "$1" >/dev/null 2>&1
    dc wait "$1" >/dev/null 2>&1 || true # kill returns before the container stops; start before that is a no-op
    dc start "$1" >/dev/null 2>&1
    local ms
    ms="$(client wait -timeout 120s -name www.example.com -want 192.0.2.10)" || fail "no answer after ${1} restarted"
    echo "{\"restart\":\"$1\",\"answer_after_ms\":${ms}}" >"${T}/restart.json"
    echo "   ${1} restarted: answered after ${ms} ms"
}
pihole_env() { # the Pi-hole web password, generated per run
    mkdir -p "${PH_PROV}/box"
    (umask 077 && echo "FTLCONF_webserver_api_password=$(openssl rand -hex 16)" >"${PH_PROV}/box/pihole.env")
}

arch="$(docker version --format '{{.Server.Arch}}')"
say "nfltr, nfltr-relay and the DNS client for linux/${arch} (released)"
mkdir -p "${PH_BIN}"
export CGO_ENABLED=0 GOOS=linux GOARCH="${arch}"
release_bins "${PH_BIN}" "${arch}" || fail "released nfltr and nfltr-relay"
go build -o "${PH_BIN}/" "./${EX}/client"
unset CGO_ENABLED GOOS GOARCH
docker build -q -t "${PH_IMAGE}" "${EX}/test" >/dev/null || fail "docker build"
: >"${T}/checks.jsonl"

say "the relay (private, TLS self-signed), provisioning, the machines, Pi-hole"
export PH_PROV="${T}/prov"
mkdir -p "${PH_PROV}/box" "${PH_PROV}/laptop"
pihole_env # first: compose reads every env_file of the services on any up
dc up -d relay >"${T}/relay-up.log" 2>&1 || { cat "${T}/relay-up.log" >&2; fail "the relay did not start"; }
RELAY_PIN=""
for _ in $(seq 60); do
    RELAY_PIN="$(dc logs --no-log-prefix relay 2>&1 | sed -n 's/^TLS certificate SHA-256: //p' | head -1)"
    [[ -n "${RELAY_PIN}" ]] && break
    sleep 1
done
[[ "${RELAY_PIN}" =~ ^[0-9a-f]{64}$ ]] || fail "no certificate fingerprint in the relay log"
export RELAY_PIN
machines_up
say "Pi-hole on the box itself (the baseline)"
dc exec -T box /opt/ph/client bench -server 127.0.0.1:53 -net udp -n 100 >"${T}/bench-local.json" || fail "local bench"
cat "${T}/bench-local.json"
# Each machine enrols at the relay with a single-use code, into its own
# config: a key made on it and a certificate from the relay's machine CA,
# named as the machine joins the organisation (an organisation machine's
# name is its account machine's name), in the owner's account. stranger
# holds a certificate but never joins the organisation; owner is the
# owner's nfltr in the relay's container.
enrol_codegen() { dc exec -T relay /opt/ph/nfltr-relay machines code --data-dir /var/lib/relay "$@"; }
setrelay() { # service machine [dir]: config /run/ph[/dir]/nfltr.json
    enrol "$2" dc run --rm -T --no-deps ${3:+-e NFLTR_CONFIG=/run/ph/$3/nfltr.json} "$1" \
        /opt/ph/nfltr config set-relay 10.233.2.10:8443 --proxy-url https://10.233.2.10:8444 --cert-sha256 "${RELAY_PIN}" --code-file -
}
mkdir -p "${PH_PROV}/box" "${PH_PROV}/laptop/eve" "${PH_PROV}/laptop/stranger"
setrelay box-agent pihole && setrelay laptop-agent laptop && setrelay laptop-agent eve eve && setrelay laptop-agent stranger stranger &&
    dc exec -T relay mkdir -p /tmp/owner &&
    enrol owner dc exec -T -e NFLTR_CONFIG=/tmp/owner/nfltr.json relay /opt/ph/nfltr config set-relay 127.0.0.1:8443 \
        --proxy-url https://127.0.0.1:8444 --cert-sha256 "${RELAY_PIN}" --code-file - ||
    fail "a machine did not enrol at the relay"
say "the owner's organisation (in the relay's container), the box and the laptop enrol"
org_owner() {
    dc exec -T -e PATH=/opt/ph:/usr/sbin:/usr/bin:/sbin:/bin -e NFLTR_CONFIG=/tmp/owner/nfltr.json \
        -e NFLTR_SERVER=127.0.0.1:8443 -e HTTP_SERVER_ADDR=https://127.0.0.1:8444 -e RPC_TLS=true \
        -e NFLTR_RELAY_CERT_SHA256="${RELAY_PIN}" relay "$@"
}
org_init home,box,guest /tmp/owner/recovery.key || fail "nfltr org init"
org_serve || fail "nfltr org serve"
join() { # service name group [dir]: a token from the owner, redeemed on that machine (dir: /run/ph/<dir>/nfltr.json)
    org_token "$2" "$3" | dc run --rm -T --no-deps ${4:+-e NFLTR_CONFIG=/run/ph/$4/nfltr.json} "$1" \
        /opt/ph/nfltr org join --root "${ORG_ROOT}" --recovery "${ORG_REC}" --token-file - >>"${T}/enrol.log" 2>&1
}
join box-agent pihole box && join laptop-agent laptop home || fail "nfltr org join"
join laptop-agent eve guest eve || fail "nfltr org join (eve)"
say "nfltr up on the box and on the laptop, the laptop's stub resolver"
dc up -d box-agent laptop-agent laptop-stub >/dev/null 2>&1
ms="$(client wait -timeout 60s)" || fail "never answered"
echo "   answered after ${ms} ms"
client bench -n 100 >"${T}/bench.json" || fail "bench"
cat "${T}/bench.json"
# Without a stub that keeps its connection: one session (and E2EE handshake) per query.
client bench -server 127.0.0.1:5353 -net tcp -n 30 >"${T}/bench-tcp-per-query.json" || fail "tcp bench"
cat "${T}/bench-tcp-per-query.json"
blocking
check "the admin page answers through the mapping" dc exec -T laptop curl -fsS -o /dev/null -m 5 http://127.0.0.1:8080/admin/login
dial() { # extra exec flags: one nfltr cat pipe session from the laptop, stdin closed
    dc exec -T "$@" laptop-agent /opt/ph/nfltr cat pipe pihole.pihole/dns --server 10.233.2.10:8444 --open-timeout 10s </dev/null
}
check "the machine's certificate opens a session" expect 0 dial
check "a machine without a certificate is refused" expect 2 dial -e NFLTR_CONFIG=/run/ph/none/nfltr.json
check "a machine not enrolled is refused" expect 4 dial -e NFLTR_CONFIG=/run/ph/stranger/nfltr.json
check "a machine outside the group is refused" expect 10 dial -e NFLTR_CONFIG=/run/ph/eve/nfltr.json
public_closed
inventory
restart box-agent

say "results"
python3 "${EX}/test/results.py" judge "${T}" || fail "results"
echo "PASS: pihole (evidence ${T})"
