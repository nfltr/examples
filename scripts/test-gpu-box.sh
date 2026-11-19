#!/usr/bin/env bash
set -euo pipefail

# ── test-gpu-box.sh ─────────────────────────────────────────────────
# End-to-end test of gpu-box (README.md there): a model server
# on a home GPU box (a stand-in that streams tokens like Ollama's OpenAI
# API) used from a laptop elsewhere, every machine a container
# (test/compose.yaml), 10 ms each way through the home router: nfltr up on
# the box (an end-to-end encrypted tcp service) and on the laptop (a
# connect: mapping), through a private relay outside; both enrolled in the
# owner's organisation (scripts/lib/org.sh).
# Judged by exit codes: completions and streams answered and correct, a
# machine without a certificate, outside the organisation or outside the
# group refused, nothing open on the home's public address, recovery after
# the box's nfltr up is killed and started, the box's listeners and the
# router's rules; latency and time to first token into bench.json.
# test/results.py judges the run into ${T}/results.json (exit code).
# GPU_BOX_OUT: the evidence directory (default: a new temp dir).
# ─────────────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}"
# shellcheck source=lib/release.sh
. scripts/lib/release.sh
EX=gpu-box
T="${GPU_BOX_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/gpu-box.XXXXXX")}"
mkdir -p "${T}"
T="$(cd "${T}" && pwd -P)"
export COMPOSE_PROJECT_NAME="gpu-box-$$"
export GB_IMAGE="nfltr-gpu-box:$$" GB_BIN="${T}/bin" GB_PROV="${T}/prov"
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
    docker image rm "${GB_IMAGE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
check() { # name, then a command: its exit code is the check
    local name="$1" rc=0
    shift
    "$@" >>"${T}/checks.log" 2>&1 || rc=$?
    echo "{\"check\":\"${name}\",\"exit\":${rc}}" >>"${T}/checks.jsonl"
    echo "   ${name}: exit ${rc}"
}
# The laptop's client, with the OPENAI_* settings of deploy/laptop.env.
client() {
    local envs=() line
    while IFS= read -r line; do envs+=(-e "${line}"); done < <(grep '^OPENAI_' "${EX}/deploy/laptop.env")
    dc exec -T "${envs[@]}" laptop /opt/gb/client "$@"
}
expect() { # want, then a command: exit 0 when the command exits with want
    local want="$1" rc=0
    shift
    "$@" || rc=$?
    [[ "${rc}" == "${want}" ]]
}
machines_up() {
    dc up -d router box laptop model >/dev/null 2>&1
    for _ in $(seq 30); do
        dc exec -T router test -e /tmp/ready 2>/dev/null && dc exec -T box test -e /tmp/ready 2>/dev/null && return 0
        sleep 1
    done
    fail "the machines never came up"
}
inventory() { # the box's and laptop's listeners, the router's rules
    local m
    for m in box laptop; do
        dc exec -T "${m}" cat /proc/net/tcp /proc/net/tcp6 >"${T}/net-${m}.txt"
    done
    dc exec -T router sh -c 'iptables -t nat -S; iptables -S' >"${T}/router-rules.txt"
}
restart() { # service: kill and start it, then ms until the laptop's next answer
    dc kill "$1" >/dev/null 2>&1
    dc wait "$1" >/dev/null 2>&1 || true # kill returns before the container stops; start before that is a no-op
    dc start "$1" >/dev/null 2>&1
    local ms
    ms="$(client wait -timeout 120s)" || fail "no answer after ${1} restarted"
    echo "{\"restart\":\"$1\",\"answer_after_ms\":${ms}}" >"${T}/restart.json"
    echo "   ${1} restarted: answered after ${ms} ms"
}

arch="$(docker version --format '{{.Server.Arch}}')"
say "nfltr, nfltr-relay, the stand-in model server and the client for linux/${arch} (released)"
mkdir -p "${GB_BIN}"
export CGO_ENABLED=0 GOOS=linux GOARCH="${arch}"
release_bins "${GB_BIN}" "${arch}" || fail "released nfltr and nfltr-relay"
go build -o "${GB_BIN}/" "./${EX}/model" "./${EX}/client"
unset CGO_ENABLED GOOS GOARCH
docker build -q -t "${GB_IMAGE}" "${EX}/test" >/dev/null || fail "docker build"
: >"${T}/checks.jsonl"

say "the relay (private, TLS self-signed), the machines"
mkdir -p "${GB_PROV}/box" "${GB_PROV}/laptop"
dc up -d relay >/dev/null 2>&1
RELAY_PIN=""
for _ in $(seq 60); do
    RELAY_PIN="$(dc logs --no-log-prefix relay 2>&1 | sed -n 's/^TLS certificate SHA-256: //p' | head -1)"
    [[ -n "${RELAY_PIN}" ]] && break
    sleep 1
done
[[ "${RELAY_PIN}" =~ ^[0-9a-f]{64}$ ]] || fail "no certificate fingerprint in the relay log"
export RELAY_PIN
machines_up
say "the model server on the box itself (the baseline)"
dc exec -T -e OPENAI_BASE_URL=http://127.0.0.1:11434/v1 box /opt/gb/client bench -n 100 >"${T}/local-bench.json" || fail "local bench"
cat "${T}/local-bench.json"
# Each machine enrols at the relay with a single-use code, into its own
# config: a key made on it and a certificate from the relay's machine CA,
# named as the machine joins the organisation (an organisation machine's
# name is its account machine's name), in the owner's account. stranger
# holds a certificate but never joins the organisation; owner is the
# owner's nfltr in the relay's container.
enrol_codegen() { dc exec -T relay /opt/gb/nfltr-relay machines code --data-dir /var/lib/relay "$@"; }
setrelay() { # service machine [dir]: config /run/gb[/dir]/nfltr.json
    enrol "$2" dc run --rm -T --no-deps ${3:+-e NFLTR_CONFIG=/run/gb/$3/nfltr.json} "$1" \
        /opt/gb/nfltr config set-relay 10.232.2.10:8443 --proxy-url https://10.232.2.10:8444 --cert-sha256 "${RELAY_PIN}" --code-file -
}
mkdir -p "${GB_PROV}/laptop/eve" "${GB_PROV}/laptop/stranger"
setrelay box-agent gpu && setrelay laptop-agent laptop && setrelay laptop-agent eve eve && setrelay laptop-agent stranger stranger &&
    dc exec -T relay mkdir -p /tmp/owner &&
    enrol owner dc exec -T -e NFLTR_CONFIG=/tmp/owner/nfltr.json relay /opt/gb/nfltr config set-relay 127.0.0.1:8443 \
        --proxy-url https://127.0.0.1:8444 --cert-sha256 "${RELAY_PIN}" --code-file - ||
    fail "a machine did not enrol at the relay"
say "the owner's organisation (in the relay's container), the box and the laptop enrol"
org_owner() {
    dc exec -T -e PATH=/opt/gb:/usr/sbin:/usr/bin:/sbin:/bin -e NFLTR_CONFIG=/tmp/owner/nfltr.json \
        -e NFLTR_SERVER=127.0.0.1:8443 -e HTTP_SERVER_ADDR=https://127.0.0.1:8444 -e RPC_TLS=true \
        -e NFLTR_RELAY_CERT_SHA256="${RELAY_PIN}" relay "$@"
}
org_init home,box,guest /tmp/owner/recovery.key || fail "nfltr org init"
org_serve || fail "nfltr org serve"
join() { # service name group [dir]: a token from the owner, redeemed on that machine (dir: /run/gb/<dir>/nfltr.json)
    org_token "$2" "$3" | dc run --rm -T --no-deps ${4:+-e NFLTR_CONFIG=/run/gb/$4/nfltr.json} "$1" \
        /opt/gb/nfltr org join --root "${ORG_ROOT}" --recovery "${ORG_REC}" --token-file - >>"${T}/enrol.log" 2>&1
}
join box-agent gpu box && join laptop-agent laptop home || fail "nfltr org join"
join laptop-agent eve guest eve || fail "nfltr org join (eve)"
say "nfltr up on the box and on the laptop"
dc up -d box-agent laptop-agent >/dev/null 2>&1
ms="$(client wait -timeout 60s)" || fail "never ready"
echo "   ready after ${ms} ms"
client bench -n 100 >"${T}/bench.json" || fail "bench"
cat "${T}/bench.json"
dial() { # extra exec flags: one nfltr cat pipe session from the laptop, stdin closed
    dc exec -T "$@" laptop-agent /opt/gb/nfltr cat pipe gpu.gpu/model --server 10.232.2.10:8444 --open-timeout 10s </dev/null
}
check "the machine's certificate opens a session" expect 0 dial
check "a machine without a certificate is refused" expect 2 dial -e NFLTR_CONFIG=/run/gb/none/nfltr.json
check "a machine not enrolled is refused" expect 4 dial -e NFLTR_CONFIG=/run/gb/stranger/nfltr.json
check "a machine outside the group is refused" expect 10 dial -e NFLTR_CONFIG=/run/gb/eve/nfltr.json
check "the home's public address: port 443 closed" expect 1 dc exec -T laptop nc -z -w 3 10.232.2.2 443
check "the home's public address: port 11434 closed" expect 1 dc exec -T laptop nc -z -w 3 10.232.2.2 11434
inventory
restart box-agent

say "results"
python3 "${EX}/test/results.py" judge "${T}" || fail "results"
echo "PASS: gpu-box (evidence ${T})"
