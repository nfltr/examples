# scripts/lib/org.sh: an organisation for a test harness, made with the
# shipped commands (https://nfltr.xyz/docs): the file root
# (`nfltr org init --root file`, its passphrase random per run and typed at
# its terminal prompts through script(1)), the issuer (`nfltr org serve`)
# and one single-use token per machine (`nfltr org token`), redeemed by
# `nfltr org join` on that machine.
#
# Source it, then define where the owner's nfltr runs (configured for the
# harness's relay; stdin passed through):
#   org_owner CMD...       run CMD at the owner
# and call:
#   org_init GROUPS RECOVERY_PATH   ORG_ROOT, ORG_REC: the fingerprints a machine joins with
#   org_serve                       the issuer, detached (its log and pid beside
#                                   RECOVERY_PATH: serve.log, serve.pid)
#   org_token NAME GROUP            prints NAME's token (GROUP: comma separated)
# An organisation machine's name is its account machine's name: each machine
# that joins as NAME enrols at the relay as NAME (scripts/lib/enrol.sh), and
# a machine reaches another machine's agent as <machine name>.<agent>/<service>.
# A machine joins with the token on stdin, never argv:
#   org_token web db | <on the machine> nfltr org join --root "$ORG_ROOT" --recovery "$ORG_REC" --token-file -
# script(1) is util-linux's (Debian: bsdutils; Alpine: util-linux-misc) or
# macOS's; the owner's place must have one.

ORG_ROOT="" ORG_REC="" ORG_DIR=""

org_init() { # GROUPS RECOVERY_PATH
    local pass out cmd
    pass="$(openssl rand -hex 16)"
    ORG_DIR="$(dirname "$2")"
    cmd="nfltr org init --root file --groups $1 --recovery-out $2"
    if [ "$(org_owner uname -s)" = Darwin ]; then
        out="$(for _ in 1 2 3 4; do printf '%s\n' "${pass}"; done | org_owner script -q /dev/null sh -c "${cmd}" 2>&1 | tr -d '\r')" || true
    else
        out="$(for _ in 1 2 3 4; do printf '%s\n' "${pass}"; done | org_owner script -qec "${cmd}" /dev/null 2>&1 | tr -d '\r')" || true
    fi
    ORG_ROOT="$(printf '%s\n' "${out}" | awk '$1=="root" {print $2}')"
    ORG_REC="$(printf '%s\n' "${out}" | awk '$1=="recovery" {print $2}')"
    case "${ORG_ROOT}:${ORG_REC}" in
    sha256:*:sha256:*) export ORG_ROOT ORG_REC ;;
    *) echo "org_init: nfltr org init printed no fingerprints: $(printf '%s\n' "${out}" | tail -3)" >&2; return 1 ;;
    esac
}

org_serve() {
    local _
    org_owner sh -c "nfltr org serve >'${ORG_DIR}/serve.log' 2>&1 </dev/null & echo \$! >'${ORG_DIR}/serve.pid'" || return 1
    for _ in $(seq 60); do
        org_owner grep -q "serving enrolments" "${ORG_DIR}/serve.log" 2>/dev/null && return 0
        sleep 0.5
    done
    echo "org_serve: the issuer never served: $(org_owner tail -3 "${ORG_DIR}/serve.log" 2>&1)" >&2
    return 1
}

org_token() { org_owner nfltr org token --name "$1" --group "$2"; }

