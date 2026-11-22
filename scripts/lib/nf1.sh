# scripts/lib/nf1.sh: the harness of the address examples (browser-terminal,
# remote-desktop, shared-database, camera-stream, udp-service). Sourced by
# bash (3.2 too) after release.sh and enrol.sh.
#
# Two machines and a private relay, each a container (nf1/compose.yaml plus
# the example's test/compose.yaml): machine A on network side-a, enrolled in
# an account (its own, by a single-use code), runs the service on its
# loopback only and `nfltr cat serve NAME --forward 127.0.0.1:PORT --address
# --address-file /run/nf1/NAME.addr`; machine B on network side-b, with no
# account and no route to A, runs `nfltr cat forward --address-file ...`.
# Only the relay sits on both networks. The address goes from A's 0600 file
# to B's through a pipe, never argv, env or a log.
#
#   nf1_init EX VAR        T (evidence dir; $VAR or a new temp dir), the binaries
#   nf1_up                 the relay, machines A and B, A enrolled
#   nf1_serve NAME         A's service and `a` (the serve), B's copy of the address
#   nf1_copy_address       A's address into B's file again
#   nf1_new_address        A serves again with --new-address
#   nf1_forward            B's `b` (the forward), started afresh
#   nf1_wait_listen        until B's forward listens
#   check NAME CMD...      CMD's exit code is the check (checks.jsonl)
#   refused CMD...         exit 0 when CMD fails (a refusal's check)
#   nf1_judge              exit 1 unless every check passed

say() { echo "── $*"; }
fail() { echo "FAIL: $* (evidence ${T})" >&2; exit 1; }
dc() { docker compose -f scripts/lib/nf1/compose.yaml -f "${EX}/test/compose.yaml" "$@"; }

nf1_init() { # EX VAR
	EX="$1"
	T="${!2:-$(mktemp -d "${TMPDIR:-/tmp}/${EX}.XXXXXX")}"
	mkdir -p "${T}"
	T="$(cd "${T}" && pwd -P)"
	export COMPOSE_PROJECT_NAME="${EX}-$$" NF1_EX="${PWD}/${EX}" NF1_BIN="${T}/bin" NF1_RUN="${T}/run" NF1_IMAGE="nfltr-${EX}:$$"
	mkdir -m 00700 -p "${NF1_BIN}" "${NF1_RUN}/a" "${NF1_RUN}/b"
	trap nf1_cleanup EXIT
	local arch
	arch="$(docker version --format '{{.Server.Arch}}')"
	say "nfltr and nfltr-relay for linux/${arch} (released)"
	release_bins "${NF1_BIN}" "${arch}" || fail "released nfltr and nfltr-relay"
	if [[ -d "${EX}/test/probe" ]]; then
		CGO_ENABLED=0 GOOS=linux GOARCH="${arch}" go build -o "${NF1_BIN}/probe" "./${EX}/test/probe" || fail "go build"
	fi
	docker build -q -t "${NF1_IMAGE}" "${EX}/test" >/dev/null || fail "docker build"
}

nf1_cleanup() {
	dc logs --no-color --timestamps >"${T}/compose.log" 2>&1 || true
	dc down -v --remove-orphans -t 1 >/dev/null 2>&1 || true
	docker image rm "${NF1_IMAGE}" >/dev/null 2>&1 || true
}

nf1_up() {
	say "the relay (private, TLS self-signed), machine A (an account) and machine B (none)"
	dc up -d relay machine-a machine-b >/dev/null 2>&1 || fail "the machines did not start"
	NF1_PIN=""
	for _ in $(seq 60); do
		NF1_PIN="$(dc logs --no-log-prefix relay 2>&1 | sed -n 's/^TLS certificate SHA-256: //p' | head -1)"
		[[ -n "${NF1_PIN}" ]] && break
		sleep 1
	done
	[[ "${NF1_PIN}" =~ ^[0-9a-f]{64}$ ]] || fail "no certificate fingerprint in the relay log"
	export NF1_PIN
	enrol_codegen() { dc exec -T relay /opt/nf1/nfltr-relay machines code --data-dir /var/lib/relay "$@"; }
	ENROL_ACCOUNT="" enrol a dc run --rm -T --no-deps a /opt/nf1/nfltr config set-relay relay:8443 \
		--proxy-url https://relay:8444 --cert-sha256 "${NF1_PIN}" --code-file - || fail "machine A did not enrol"
}

nf1_serve() { # NAME: A's service (every service of the example's compose but a, b) and its serve
	NF1_NAME="$1"
	say "machine A: the service on its loopback, served under an address"
	dc up -d a "${NF1_SERVICES[@]}" >/dev/null 2>&1 || fail "machine A's service did not start"
	nf1_copy_address
}

nf1_copy_address() { # A's address file, written by nfltr cat serve (0600), into B's (0600): a pipe
	for _ in $(seq 60); do
		dc exec -T a test -s "/run/nf1/${NF1_NAME}.addr" 2>/dev/null && break
		sleep 1
	done
	[[ "$(dc exec -T a stat -c %a "/run/nf1/${NF1_NAME}.addr" 2>/dev/null)" == 600 ]] || fail "no address file of mode 0600 on A"
	dc exec -T a cat "/run/nf1/${NF1_NAME}.addr" |
		dc exec -T machine-b sh -c "umask 077; cat >/run/nf1/${NF1_NAME}.addr.new && mv /run/nf1/${NF1_NAME}.addr.new /run/nf1/${NF1_NAME}.addr" ||
		fail "the address did not reach B"
}

nf1_new_address() { # A serves again with --new-address: a new address, the old one ends
	local old
	say "machine A serves again with --new-address"
	old="$(dc exec -T a sha256sum "/run/nf1/${NF1_NAME}.addr")"
	dc rm -sf a >/dev/null 2>&1
	NF1_NEW_ADDRESS=--new-address dc up -d a >/dev/null 2>&1 || fail "A's serve did not start again"
	for _ in $(seq 60); do
		[[ "$(dc exec -T a sha256sum "/run/nf1/${NF1_NAME}.addr" 2>/dev/null)" != "${old}" ]] && return 0
		sleep 1
	done
	fail "A's address file kept the old address"
}

nf1_forward() {
	say "machine B: nfltr cat forward --address-file (no account)"
	dc up -d --force-recreate b >/dev/null 2>&1 || fail "B's forward did not start"
}

nf1_wait_listen() { # until B's forward listens
	for _ in $(seq 60); do
		dc logs --no-log-prefix b 2>&1 | grep -q "connect forward: listening" && return 0
		sleep 1
	done
	fail "B's forward never listened"
}

check() { # NAME CMD...
	local name="$1" rc=0
	shift
	echo "== ${name}: $*" >>"${T}/checks.log"
	"$@" >>"${T}/checks.log" 2>&1 || rc=$?
	echo "{\"check\":\"${name}\",\"exit\":${rc}}" >>"${T}/checks.jsonl"
	echo "   ${name}: exit ${rc}"
}

refused() { ! "$@"; }

nf1_judge() {
	if grep -qv '"exit":0}' "${T}/checks.jsonl"; then
		fail "$(grep -cv '"exit":0}' "${T}/checks.jsonl") check(s) failed"
	fi
	echo "PASS: ${EX} example, $(wc -l <"${T}/checks.jsonl" | tr -d ' ') checks (evidence ${T})"
}
