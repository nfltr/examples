#!/usr/bin/env bash
set -euo pipefail

# ── test-reverse-proxy.sh ───────────────────────────────────
# End-to-end test of reverse-proxy (README.md there): a home
# server with a reverse proxy (Caddy, then Traefik, each pinned by digest)
# in front of three services by host and path, used from a visitor on the
# internet, every machine a container (test/compose.yaml), 10 ms each way
# through the home router. nfltr up on the server dials out to a relay and
# gives each site an end-to-end encrypted link; the proxy listens on
# loopback only (deploy/).
# Per arm (the proxy), judged by exit codes: routing by host and path,
# the proxy's Basic auth and the header it adds, what the services see of
# the visitor (address, X-Forwarded-*), a WebSocket, which public ports
# answer and what the server listens on, recovery after nfltr up is killed
# and started; latency into bench.json. Then the services' view with the
# proxy's trusted-proxy line removed. test/results.py judges the run into
# ${T}/results.json.
# RP_EXAMPLE_OUT: the evidence directory (default: a new temp dir).
# ─────────────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}"
# shellcheck source=lib/release.sh
. scripts/lib/release.sh
# shellcheck source=lib/enrol.sh
. scripts/lib/enrol.sh
EX=reverse-proxy
T="${RP_EXAMPLE_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/reverse-proxy.XXXXXX")}"
mkdir -p "${T}"
T="$(cd "${T}" && pwd -P)"
export COMPOSE_PROJECT_NAME="reverse-proxy-$$"
export RP_IMAGE="nfltr-reverse-proxy:$$" RP_BIN="${T}/bin"
# Caddy 2.10.2 and Traefik 3.5, by digest.
export CADDY_IMAGE="caddy:2.10.2-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d"
export TRAEFIK_IMAGE="traefik:v3.5@sha256:16acb89c6db341182970d6fdafece31303b0a380a8ed7aa51682e225229bf1d2"
VISITOR=10.234.2.30
ARM="" PROXY=""
say() { echo "── $*"; }
fail() { echo "FAIL: $* (evidence ${T})" >&2; exit 1; }
dc() { docker compose -f "${EX}/test/compose.yaml" --profile "${PROXY:-none}" "$@"; }
arm_down() {
    [[ -n "${ARM}" ]] || return 0
    dc logs --no-color --timestamps >"${T}/${ARM}/compose.log" 2>&1 || true
    dc down -v --remove-orphans -t 1 >/dev/null 2>&1 || true
}
cleanup() {
    arm_down
    docker image rm "${RP_IMAGE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
check() { # name, then a command: its exit code is the check; its stdout goes to <arm>/<name>.json
    local name="$1" rc=0
    shift
    "$@" >"${T}/${ARM}/${name}.json" 2>>"${T}/${ARM}/checks.log" || rc=$?
    echo "{\"arm\":\"${ARM}\",\"check\":\"${name}\",\"exit\":${rc}}" >>"${T}/checks.jsonl"
    echo "   ${name}: exit ${rc}"
}
expect() { # want, then a command: exit 0 when the command exits with want
    local want="$1" rc=0
    shift
    "$@" || rc=$?
    [[ "${rc}" == "${want}" ]]
}
probe() { dc exec -T visitor /opt/rp/probe "$@"; }
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

arch="$(docker version --format '{{.Server.Arch}}')"
say "nfltr, nfltr-relay, the services and the probe for linux/${arch} (released)"
mkdir -p "${RP_BIN}"
export CGO_ENABLED=0 GOOS=linux GOARCH="${arch}"
release_bins "${RP_BIN}" "${arch}" || fail "released nfltr and nfltr-relay"
go build -o "${RP_BIN}/svc" "./${EX}/svc"
go build -o "${RP_BIN}/probe" "./${EX}/test/probe"
unset CGO_ENABLED GOOS GOARCH
docker build -q -t "${RP_IMAGE}" "${EX}/test" >/dev/null || fail "docker build"
docker pull -q "${CADDY_IMAGE}" >/dev/null && docker pull -q "${TRAEFIK_IMAGE}" >/dev/null || fail "docker pull"
: >"${T}/checks.jsonl"
started="$(date +%s)"

say "the admin login (one bcrypt hash for both proxies), the links' certificate"
mkdir -p "${T}/shared"
(
    umask 077
    pw="$(openssl rand -hex 16)"
    printf 'owner:%s\n' "${pw}" >"${T}/shared/login"
    printf 'owner:%s\n' "$(openssl rand -hex 16)" >"${T}/shared/wrong-login"
    printf '%s\n' "${pw}" | docker run --rm -i "${CADDY_IMAGE}" caddy hash-password >"${T}/shared/hash"
)
grep -q '^\$2' "${T}/shared/hash" || fail "no bcrypt hash"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 7 -subj /CN=share.test \
    -addext subjectAltName=DNS:*.share.test -keyout "${T}/shared/link.key" -out "${T}/shared/link.crt" 2>/dev/null

# prepare_run: the arm's files under ${RP_RUN}: the proxy's configuration as
# the example ships it, the login, the links' certificate.
prepare_run() {
    export RP_RUN="${T}/${ARM}/run"
    mkdir -p "${RP_RUN}/proxy" "${RP_RUN}/home"
    cp "${T}/shared/login" "${T}/shared/wrong-login" "${T}/shared/link.crt" "${RP_RUN}/"
    install -m 600 "${T}/shared/link.key" "${RP_RUN}/link.key"
    echo "ADMIN_HASH='$(cat "${T}/shared/hash")'" >"${RP_RUN}/caddy.env"
    cp -R "${EX}/deploy/${PROXY}/." "${RP_RUN}/proxy/"
    if [[ "${PROXY}" == traefik ]]; then
        echo "owner:$(cat "${T}/shared/hash")" >"${RP_RUN}/proxy/users"
    fi
}

machines_up() {
    dc up -d router server visitor services >/dev/null 2>&1 || fail "${ARM}: compose up"
    for _ in $(seq 30); do
        dc exec -T router test -e /tmp/ready 2>/dev/null && dc exec -T server test -e /tmp/ready 2>/dev/null && return 0
        sleep 1
    done
    fail "${ARM}: the machines never came up"
}

inventory() { # what is open from the internet, the server's listeners, the router's rules
    probe ports -host 10.234.2.2 -ports 80,443,8080,9001 >"${T}/${ARM}/ports-public.json" || fail "${ARM}: ports"
    dc exec -T server cat /proc/net/tcp /proc/net/tcp6 >"${T}/${ARM}/net-server.txt"
    dc exec -T router sh -c 'iptables -t nat -S PREROUTING; iptables -S FORWARD' >"${T}/${ARM}/router-rules.txt"
}

# the arm's checks against APP and ADMIN (URLs) with the visitor's flags F
checks() {
    check route-host-app probe get -url "${APP}/" "${F[@]}" -want-service photos
    check route-path-api probe get -url "${APP}/api/items" "${F[@]}" -want-service api
    check route-host-admin probe get -url "${ADMIN}/" "${F[@]}" -auth /run/rp/login -want-service admin -want-header X-Auth-User=owner
    check auth-none-refused probe get -url "${ADMIN}/" "${F[@]}" -want-status 401
    check auth-wrong-refused probe get -url "${ADMIN}/" "${F[@]}" -auth /run/rp/wrong-login -want-status 401
    check headers-app probe get -url "${APP}/headers" "${F[@]}" -want-service photos
    # a visitor that sends its own forwarded headers, claiming another address
    check headers-forged probe get -url "${APP}/headers" "${F[@]}" -want-service photos \
        -header X-Forwarded-For=203.0.113.9 -header X-Real-Ip=203.0.113.9 -header X-Forwarded-Host=evil.example -header X-Forwarded-Proto=http
    check headers-admin probe get -url "${ADMIN}/headers" "${F[@]}" -auth /run/rp/login -want-service admin
    check websocket probe ws -url "${APP/https:/wss:}/ws" "${F[@]}" -n 100 -want-service photos
    probe bench -url "${APP}/api/items" "${F[@]}" -n 200 >"${T}/${ARM}/bench.json" || fail "${ARM}: bench"
    cat "${T}/${ARM}/bench.json"
}

restart() { # service: kill and start it; ms from the kill until the app answers again
    local t0
    t0="$(ms)"
    dc kill "$1" >/dev/null 2>&1
    dc wait "$1" >/dev/null 2>&1 || true # kill returns before the container stops; start before that is a no-op
    dc start "$1" >/dev/null 2>&1
    probe wait -url "${APP}/" "${F[@]}" -timeout 120s >/dev/null || fail "${ARM}: no answer after ${1} restarted"
    echo "{\"service\":\"$1\",\"ms\":$(($(ms) - t0))}" >"${T}/${ARM}/restart.json"
    echo "   ${1} restarted: answering after $(($(ms) - t0)) ms"
}

for PROXY in ${RP_PROXIES:-caddy traefik}; do
    ARM="${PROXY}"
    mkdir -p "${T}/${ARM}"
    prepare_run
    say "${ARM}: the machines"
    machines_up
    dc up -d relay "${PROXY}" >/dev/null 2>&1
    RELAY_PIN=""
    for _ in $(seq 60); do
        RELAY_PIN="$(dc logs --no-log-prefix relay 2>&1 | sed -n 's/^TLS certificate SHA-256: //p' | head -1)"
        [[ -n "${RELAY_PIN}" ]] && break
        sleep 1
    done
    [[ "${RELAY_PIN}" =~ ^[0-9a-f]{64}$ ]] || fail "${ARM}: no certificate fingerprint in the relay log"
    export RELAY_PIN
    # The agent's machine enrols with a single-use code into its own
    # config (HOME): a certificate from the relay's machine CA, no key.
    enrol_codegen() { dc exec -T relay /opt/rp/nfltr-relay machines code --data-dir /var/lib/relay "$@"; }
    rm -rf "${RP_RUN}/home" && mkdir -p "${RP_RUN}/home"
    enrol server dc run --rm -T --no-deps agent /opt/rp/nfltr config set-relay 10.234.2.10:8443 \
        --proxy-url https://10.234.2.10:8444 --cert-sha256 "${RELAY_PIN}" --code-file - || fail "${ARM}: the agent's machine did not enrol"
    say "${ARM}: nfltr up (deploy/nfltr.yaml)"
    dc up -d agent >/dev/null 2>&1
    link() { # service: its link's host name from nfltr up's summary
        dc logs --no-log-prefix agent 2>/dev/null | grep -E "^$1[[:space:]]" | grep -o 'https://[a-z0-9-]*\.share\.test' | tail -1 || true
    }
    APP="" ADMIN=""
    for _ in $(seq 60); do
        APP="$(link app-site)" ADMIN="$(link admin-site)"
        [[ -n "${APP}" && -n "${ADMIN}" ]] && break
        sleep 1
    done
    [[ -n "${APP}" && -n "${ADMIN}" ]] || fail "${ARM}: no links in nfltr up's log"
    F=(-addr 10.234.2.10:8443 -ca /run/rp/link.crt)
    probe wait -url "${APP}/" "${F[@]}" -timeout 60s >/dev/null || fail "${ARM}: never answered"
    checks
    check guessed-link-refused expect 1 probe get -url "https://aaaaaaaaaaaaaaaaaaaaaaaaaa.share.test/" "${F[@]}"
    inventory
    restart agent
    [[ "$(link app-site)" == "${APP}" ]] || fail "${ARM}: the link changed with the restart"
    say "${ARM}: the proxy without its trusted-proxy line (what the services see then)"
    perl -0pi -e 's/\tservers \{\n\t\ttrusted_proxies[^\n]*\n\t\}\n//; s/\n *forwardedHeaders:[^\n]*//' "${RP_RUN}/proxy/"*.y*ml "${RP_RUN}/proxy/Caddyfile" 2>/dev/null || true
    if grep -rqE 'trusted_proxies|trustedIPs' "${RP_RUN}/proxy"; then fail "${ARM}: the trust line is still there"; fi
    dc restart "${PROXY}" >/dev/null 2>&1
    probe wait -url "${APP}/" "${F[@]}" -timeout 60s >/dev/null || fail "${ARM}: no answer without the trust line"
    probe get -url "${APP}/headers" "${F[@]}" -want-service photos >"${T}/${ARM}/headers-app-untrusted.json" || fail "${ARM}: untrusted headers"
    arm_down
done
ARM="" PROXY=""

say "results"
echo "{\"wall_s\":$(($(date +%s) - started)),\"visitor\":\"${VISITOR}\"}" >"${T}/run.json"
python3 "${EX}/test/results.py" judge "${T}" || fail "results"
echo "PASS: reverse-proxy example (evidence ${T})"
