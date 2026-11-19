#!/usr/bin/env bash
set -euo pipefail

# ── test-dotnet-fleet.sh ────────────────────────────────────────────
# End-to-end test of dotnet-fleet (MIGRATION.md there): adding nfltr to a
# .NET 8 fleet (a control plane, three edge agents, one proto and one
# business logic in common/). The app as written (app/) and the app with
# the nfltr connect sidecar (with-nfltr/) both run, every "machine" in
# containers. nfltr and nfltr-relay are the released binaries; the .NET
# programs in mcr.microsoft.com/dotnet/sdk:8.0 (no dotnet on the host).
# Every check is an exit code:
#   app/ (test/compose.app.yaml): agents dial the control plane's TLS
#     endpoint (a private CA, its certificate issued here); (b)
#     agent-initiated Fleet.Session, a deadline, an agent restart; latency
#     over that direct TLS connection: the baseline
#   the patch: dotnet-fleet/migrate.sh applies migration.patch to a copy of
#     app/; the result must equal with-nfltr/ and is what the with-nfltr
#     image is built from
#   with-nfltr/ (test/compose.yaml), through a private relay:
#     (a) control plane -> agent by name, through a connect: mapping and
#         through nfltr cat pipe: three agents, five streamed progress updates each
#     (b) agent-initiated Fleet.Session: commands down, updates up
#     a 1 s deadline on a 5 s command, both shapes; every agent cancels it
#     edge-1 (agent and the sidecar it owns) killed mid-command: (a) sees
#     UNAVAILABLE, then ok once it is back; edge-2's agent alone killed
#     mid-command: (b) the same
#     E2EE in organisation mode (every machine enrolled: scripts/lib/org.sh):
#     nfltr cat pipe from a machine outside the service's groups exits 10, a
#     plain open of an end-to-end encrypted service exits 4
#   edge-2 at a customer site, both stacks: its only way out is the site's
#     HTTP proxy, which allows CONNECT to one list of addresses: no direct
#     route, a CONNECT elsewhere refused (403), its traffic through the proxy
#   the same business results in both stacks: every agent's outcome,
#   progress count and output are equal on (b) in app/ and on (a) and (b)
#   with nfltr; no fleet machine listens on anything but loopback with nfltr
# Then latency (the direct TLS baseline in app/; e2ee on and off, mapping,
# dial, session, streaming with nfltr), restart recovery, the network
# listeners of every fleet machine (/proc/net/tcp), processes, certificates
# and the patch's apply time: ${T}/results.json, summarized on stdout.
# dotnet-fleet/test/report.py writes README.md's and MIGRATION.md's
# measured sections from one or more runs' results.json.
# DOTNET_FLEET_KEEP=1 leaves the with-nfltr stack up.
# ─────────────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}"
# shellcheck source=lib/release.sh
. scripts/lib/release.sh
EX=dotnet-fleet
T="$(mktemp -d "${TMPDIR:-/tmp}/dotnet-fleet.XXXXXX")"
T="$(cd "$T" && pwd -P)"
export COMPOSE_PROJECT_NAME="dotnet-fleet-$$"
export FLEET_BIN="${T}/bin" FLEET_DIR="${T}/fleet" FLEET_TLS="${T}/tls"
# shellcheck source=lib/org.sh
. scripts/lib/org.sh
# shellcheck source=lib/enrol.sh
. scripts/lib/enrol.sh
say() { echo "── $*"; }
fail() { echo "FAIL: $* (evidence ${T})" >&2; exit 1; }
STACK=with-nfltr # which stack dc, ctl and the checks below act on
dc() {
    if [[ "${STACK}" == app ]]; then
        docker compose -p "${COMPOSE_PROJECT_NAME}-app" -f "${EX}/test/compose.app.yaml" "$@"
    else
        docker compose -f "${EX}/test/compose.yaml" "$@"
    fi
}
ctl() { dc exec -T controlplane dotnet /app/controlplane/ControlPlane.dll "$@"; }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
stack_down() { # [keep]
    dc logs --no-color >"${T}/compose-${STACK}.log" 2>&1 || true
    [[ "${1:-}" == keep ]] && { echo "kept: docker compose -p ${COMPOSE_PROJECT_NAME} -f ${EX}/test/compose.yaml"; return; }
    dc down -v --remove-orphans -t 1 >/dev/null 2>&1 || true
}
down() {
    STACK=app stack_down
    STACK=with-nfltr stack_down "$([[ "${DOTNET_FLEET_KEEP:-0}" == 1 ]] && echo keep)"
}
trap down EXIT
retry() { # attempts command...: until it exits 0, one attempt a second
    local n="$1"
    shift
    for _ in $(seq "${n}"); do
        "$@" >>"${T}/ready.out" 2>&1 && return 0
        sleep 1
    done
    return 1
}
check() { # name, then ControlPlane arguments: it must exit 0
    local name="$1"
    shift
    ctl "$@" >"${T}/${name}.out" 2>&1 || { cat "${T}/${name}.out" >&2; fail "${name}"; }
    tail -1 "${T}/${name}.out"
}
cancellations() { # want, agents...: every agent logged the cancellation of its commands, its handlers no error
    local want="$1" n=0
    shift
    for _ in $(seq 20); do
        n="$(dc logs "$@" 2>&1 | grep -c 'cancelled at step' || true)"
        (( n >= want )) && break
        sleep 0.5
    done
    (( n == want )) || fail "the agents cancelled ${n} commands, want ${want}"
    ! dc logs "$@" 2>&1 | grep 'Error when executing service method' || fail "an agent's handler failed on cancellation"
    echo "the agents cancelled ${n} of ${want} commands"
}
restart() { # name container via: kill the container mid-command, start it again
    local name="$1" container="$2" via="$3" agent="$2"
    ctl dispatch --via "${via}" --agents "${agent}" --steps 20 --step-ms 300 --expect unavailable,ok --retry-s 120 >"${T}/${name}.out" 2>&1 &
    local pid=$!
    sleep 2
    local t_kill
    t_kill="$(now_ms)"
    dc kill "${container}" >/dev/null 2>&1
    dc start "${container}" >/dev/null 2>&1
    echo "{\"restart\":\"${name}\",\"kill_ms\":${t_kill}}" >"${T}/${name}.times"
    wait "${pid}" || { cat "${T}/${name}.out" >&2; fail "${name}"; }
    tail -1 "${T}/${name}.out"
}
bench() { ctl bench "$@" | sed "s/^{/{\"stack\":\"${STACK}\",/" | tee -a "${T}/bench.jsonl" >/dev/null || fail "bench $*"; }
site_proxy() { # service host port: edge-2's machine reaches host:port only through its site's proxy
    local svc="$1" host="$2" port="$3" answer
    ! dc exec -T "${svc}" timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null || fail "${STACK}: edge-2 reaches ${host}:${port} without the proxy"
    answer="$(dc exec -T "${svc}" timeout 5 bash -c 'exec 3<>/dev/tcp/site-b-proxy/3128; printf "CONNECT edge-1:50051 HTTP/1.1\r\nHost: edge-1:50051\r\n\r\n" >&3; head -1 <&3' | tr -d '\r')"
    [[ "${answer}" == "HTTP/1.1 403 Forbidden" ]] || fail "${STACK}: the site's proxy answered '${answer}' to a CONNECT outside its list, want 403"
    dc logs --no-log-prefix site-b-proxy >"${T}/site-proxy-${STACK}.jsonl" 2>&1
    echo "${STACK}: edge-2 has no direct route to ${host}:${port}; its proxy refuses other targets; CONNECTs: $(grep -c '"allowed":true' "${T}/site-proxy-${STACK}.jsonl")"
}
inventory() { # machine=service...: each fleet machine's TCP listeners, then the stack's processes
    local m
    for m in "$@"; do
        dc exec -T "${m#*=}" cat /proc/net/tcp /proc/net/tcp6 >"${T}/net-${STACK}-${m%%=*}.txt" 2>/dev/null || fail "no /proc/net/tcp in ${m}"
    done
    dc top >"${T}/top-${STACK}.txt" 2>&1 || fail "docker compose top"
}
: >"${T}/bench.jsonl"

arch="$(docker version --format '{{.Server.Arch}}')"
say "nfltr, nfltr-relay and the test's site proxy for linux/${arch} (released)"
mkdir -p "${FLEET_BIN}"
release_bins "${FLEET_BIN}" "${arch}" || fail "released nfltr and nfltr-relay"
CGO_ENABLED=0 GOOS=linux GOARCH="${arch}" go build -o "${FLEET_BIN}/" ./${EX}/test/siteproxy

say "the patch: migrate.sh applies migration.patch to a copy of app/ (it must equal with-nfltr/)"
"${EX}/migrate.sh" "${T}/migrated" | tee "${T}/migrate.out" || fail "migrate.sh"
for v in app with-nfltr; do
    mkdir -p "${T}/ctx-${v}"
    cp -R "${EX}/proto" "${EX}/common" "${T}/ctx-${v}/"
done
cp -R "${EX}/app" "${T}/ctx-app/fleet"
cp -R "${T}/migrated" "${T}/ctx-with-nfltr/fleet" # what runs with nfltr is the applied patch

say "the .NET images, app and with-nfltr (mcr.microsoft.com/dotnet/sdk:8.0 builds, aspnet:8.0 runs)"
for v in app with-nfltr; do
    docker build -q -f "${EX}/test/Dockerfile" -t "nfltr-dotnet-fleet:${v}" "${T}/ctx-${v}" >/dev/null || fail "docker build ${v}"
done

STACK=app
say "APP: the fleet's private CA and the control plane's certificate for its public name"
mkdir -m 700 "${FLEET_TLS}"
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' >"${T}/ca.ext"
printf 'subjectAltName=DNS:controlplane.fleet.example\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\n' >"${T}/server.ext"
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=fleet-ca \
    -keyout "${T}/ca.key" -out "${T}/ca.csr" 2>/dev/null
openssl x509 -req -in "${T}/ca.csr" -signkey "${T}/ca.key" -days 30 -extfile "${T}/ca.ext" -out "${FLEET_TLS}/ca.crt" 2>/dev/null
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=controlplane.fleet.example \
    -keyout "${FLEET_TLS}/controlplane.key" -out "${T}/controlplane.csr" 2>/dev/null
openssl x509 -req -in "${T}/controlplane.csr" -CA "${FLEET_TLS}/ca.crt" -CAkey "${T}/ca.key" -CAcreateserial \
    -days 30 -extfile "${T}/server.ext" -out "${FLEET_TLS}/controlplane.crt" 2>/dev/null
chmod 600 "${T}/ca.key" "${FLEET_TLS}/controlplane.key"
openssl verify -CAfile "${FLEET_TLS}/ca.crt" "${FLEET_TLS}/controlplane.crt" >/dev/null || fail "the control plane's certificate"

say "APP: the control plane on its public TLS port, three agents dialing it"
t_up="$(now_ms)"
dc up -d >/dev/null 2>&1
retry 120 ctl dispatch --via session --agents edge-1,edge-2,edge-3 --steps 1 --step-ms 0 || fail "app: the agents' sessions never opened"
echo "{\"stack\":\"app\",\"ready_ms\":$(( $(now_ms) - t_up ))}" >"${T}/ready-app.json"
cat "${T}/ready-app.json"
say "APP (b) Fleet.Session: 3 agents, 5 progress updates each"
check app-b-session dispatch --via session --agents edge-1,edge-2,edge-3 --steps 5 --step-ms 100
say "APP: no (a): the control plane cannot reach an agent by name"
check app-a-refused dispatch --via mapping --agents edge-1 --steps 1 --step-ms 0 --expect unimplemented
say "APP deadline: 1 s on a 5 s command; every agent cancels it"
check app-b-deadline dispatch --via session --agents edge-1,edge-2,edge-3 --steps 50 --step-ms 100 --deadline-ms 1000 --expect deadline
cancellations 3 edge-1 edge-2 edge-3
say "APP: edge-2 killed mid-command, started again: (b) UNAVAILABLE, then ok"
restart app-restart-edge-2 edge-2 session
say "APP: edge-2 at a customer site: only its HTTP proxy leads out"
site_proxy edge-2 controlplane.fleet.example 8443
say "APP: listeners, processes; latency over the direct TLS connection (the baseline)"
inventory controlplane=controlplane edge-1=edge-1 edge-2=edge-2 edge-3=edge-3
bench --via session --agents edge-1,edge-2,edge-3 --steps 0 --n 100
bench --via session --agents edge-1,edge-3 --steps 100 --step-ms 0 --n 20
stack_down
STACK=with-nfltr

say "WITH NFLTR provisioning: the sidecar files"
mkdir -m 700 "${FLEET_DIR}"
SC="${T}/migrated/sidecar"
cp "${SC}/controlplane.yaml" "${FLEET_DIR}/"
cp "${SC}/edge-agent.yaml" "${FLEET_DIR}/edge-1.yaml"
sed 's/edge-1/edge-2/g' "${SC}/edge-agent.yaml" >"${FLEET_DIR}/edge-2.yaml"
# edge-3 is not on E2EE yet (controlplane.yaml maps it with plain: true).
sed -e 's/edge-1/edge-3/g' -e 's/e2ee: true, allow_group: \[controlplane\]/e2ee: false/' "${SC}/edge-agent.yaml" >"${FLEET_DIR}/edge-3.yaml"
grep -q 'e2ee: false' "${FLEET_DIR}/edge-3.yaml" || fail "edge-3's sidecar file still has e2ee on"

say "WITH NFLTR: relay (private, TLS self-signed)"
dc up -d relay >/dev/null 2>&1
fp=""
for _ in $(seq 60); do
    fp="$(dc logs --no-log-prefix relay 2>&1 | sed -n 's/^TLS certificate SHA-256: //p' | head -1)"
    [[ -n "${fp}" ]] && break
    sleep 1
done
[[ "${fp}" =~ ^[0-9a-f]{64}$ ]] || fail "no certificate fingerprint in the relay log"
export RELAY_PIN="${fp}"
# Each machine enrols at the relay with a single-use code into its own
# config (<machine>/nfltr.json, beside its organisation enrolment): a key
# made on it and a certificate from the relay's machine CA, named as the
# machine joins the organisation (an organisation machine's name is its
# account machine's name), in the owner's account; owner is the owner's
# nfltr in the relay's container.
enrol_codegen() { dc exec -T relay /opt/nfltr/nfltr-relay machines code --data-dir /var/lib/relay "$@"; }
setrelay() { # service machine
    enrol "$2" dc run --rm -T --no-deps "$1" /opt/nfltr/nfltr config set-relay relay:8443 \
        --proxy-url https://relay:8444 --cert-sha256 "${RELAY_PIN}" --code-file -
}
for m in controlplane edge-1 edge-2 edge-3; do (umask 077 && mkdir -p "${FLEET_DIR}/${m}"); done
dc up -d site-b-proxy >/dev/null 2>&1
setrelay controlplane-sidecar controlplane && setrelay edge-1 edge-1 && setrelay edge-2-sidecar edge-2 &&
    setrelay edge-3-sidecar edge-3 && dc exec -T relay mkdir -p /tmp/owner &&
    enrol owner dc exec -T -e NFLTR_CONFIG=/tmp/owner/nfltr.json relay /opt/nfltr/nfltr config set-relay 127.0.0.1:8443 \
        --proxy-url https://127.0.0.1:8444 --cert-sha256 "${RELAY_PIN}" --code-file - ||
    fail "a machine did not enrol at the relay"

say "WITH NFLTR provisioning: the owner's organisation (in the relay's container); every machine enrols once"
org_owner() {
    dc exec -T -e PATH=/opt/nfltr:/usr/sbin:/usr/bin:/sbin:/bin -e NFLTR_CONFIG=/tmp/owner/nfltr.json \
        -e NFLTR_SERVER=127.0.0.1:8443 -e HTTP_SERVER_ADDR=https://127.0.0.1:8444 -e RPC_TLS=true \
        -e NFLTR_RELAY_CERT_SHA256="${RELAY_PIN}" relay "$@"
}
org_init controlplane,edge /tmp/owner/recovery.key || fail "nfltr org init"
org_serve || fail "nfltr org serve"
join() { # service name group: a token from the owner, redeemed on that machine (its NFLTR_CONFIG)
    org_token "$2" "$3" | dc run --rm -T --no-deps "$1" \
        /opt/nfltr/nfltr org join --root "${ORG_ROOT}" --recovery "${ORG_REC}" --token-file - >>"${T}/enrol.log" 2>&1
}
join controlplane-sidecar controlplane controlplane && join edge-1 edge-1 edge && join edge-2-sidecar edge-2 edge &&
    join edge-3-sidecar edge-3 edge || fail "nfltr org join"

say "WITH NFLTR: control plane, three agents, their sidecars"
t_up="$(now_ms)"
dc up -d >/dev/null 2>&1
retry 120 ctl dispatch --via session --agents edge-1,edge-2,edge-3 --steps 1 --step-ms 0 || fail "the agents' sessions never opened"
echo "{\"stack\":\"with-nfltr\",\"ready_ms\":$(( $(now_ms) - t_up ))}" >"${T}/ready-with-nfltr.json"
cat "${T}/ready-with-nfltr.json"
retry 60 ctl dispatch --via mapping --agents edge-1,edge-2,edge-3 --steps 1 --step-ms 0 || fail "the agents' mappings never answered"
say "WITH NFLTR (a) control plane -> agent by name, connect: mapping: 3 agents, 5 progress updates each"
check a-mapping dispatch --via mapping --agents edge-1,edge-2,edge-3 --steps 5 --step-ms 100
say "WITH NFLTR (a) the same through nfltr cat pipe (no mapping)"
check a-dial dispatch --via dial --agents edge-1,edge-2,edge-3 --steps 5 --step-ms 100
say "WITH NFLTR (b) agent-initiated Fleet.Session: commands down, updates up"
check b-session dispatch --via session --agents edge-1,edge-2,edge-3 --steps 5 --step-ms 100

say "WITH NFLTR deadline: 1 s on a 5 s command, both shapes; every agent cancels it"
check a-deadline dispatch --via mapping --agents edge-1,edge-2,edge-3 --steps 50 --step-ms 100 --deadline-ms 1000 --expect deadline
check b-deadline dispatch --via session --agents edge-1,edge-2,edge-3 --steps 50 --step-ms 100 --deadline-ms 1000 --expect deadline
cancellations 6 edge-1 edge-2 edge-3

say "WITH NFLTR E2EE: a machine outside the service's groups exits 10, a plain open of an end-to-end encrypted service exits 4"
rc=0
dc exec -T edge-3-sidecar /opt/nfltr/nfltr cat pipe edge-1.edge-1/execute --server relay:8444 </dev/null >/dev/null 2>"${T}/other-group.err" || rc=$?
(( rc == 10 )) || { cat "${T}/other-group.err" >&2; fail "dial from a machine of group edge exited ${rc}, want 10"; }
rc=0
dc exec -T controlplane /opt/nfltr/nfltr cat pipe edge-1.edge-1/execute --plain </dev/null >/dev/null 2>"${T}/plain-open.err" || rc=$?
(( rc == 4 )) || { cat "${T}/plain-open.err" >&2; fail "a plain dial of an e2ee service exited ${rc}, want 4"; }
echo "another group: exit 10; plain open of an e2ee service: exit 4"

say "WITH NFLTR edge-1 killed mid-command (the agent and the sidecar it owns), started again: (a) UNAVAILABLE, then ok"
restart restart-edge-1 edge-1 mapping
say "WITH NFLTR edge-2's agent killed mid-command (its sidecar keeps running), started again: (b) UNAVAILABLE, then ok"
restart restart-edge-2 edge-2 session

say "WITH NFLTR: edge-2 at a customer site: only its HTTP proxy leads out"
site_proxy edge-2-sidecar relay 8444

say "the same business results in app/ and with nfltr"
python3 "${EX}/test/compare.py" "${T}" || fail "the business results differ between app/ and with nfltr"
say "WITH NFLTR: listeners, processes; latency"
inventory controlplane=controlplane edge-1=edge-1 edge-2=edge-2 edge-3=edge-3
bench --via mapping --agents edge-1,edge-2,edge-3 --steps 0 --n 100
bench --via mapping --agents edge-1,edge-2,edge-3 --steps 0 --n 30 --fresh true
bench --via dial --agents edge-1,edge-3 --steps 0 --n 100
bench --via dial --agents edge-1,edge-3 --steps 0 --n 30 --fresh true
bench --via session --agents edge-1,edge-2,edge-3 --steps 0 --n 100
bench --via mapping --agents edge-1,edge-3 --steps 100 --step-ms 0 --n 20
bench --via session --agents edge-1,edge-3 --steps 100 --step-ms 0 --n 20
python3 "${EX}/test/results.py" "${T}" || fail "results"
echo "PASS: dotnet-fleet example end to end (evidence ${T})"
