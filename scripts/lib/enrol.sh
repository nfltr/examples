# scripts/lib/enrol.sh: a test machine's relay identity by a single-use
# enrolment code (no API key on any test machine). Sourced by bash (3.2 too). The relay mints the code
# (`nfltr-relay machines code --data-dir D --name NAME --account admin`: the
# machine joins the data dir's admin account, so it reaches the other test
# machines), and the machine redeems it with `nfltr config set-relay ...
# --code-file -` (or `config login`, `node join --enrol-code-file -`) into its
# own NFLTR_CONFIG: a key made there, a certificate from the relay's machine
# CA. The code goes through a pipe only, never argv, env or a file.
#
# Define where the relay's nfltr-relay runs, then call enrol:
#   enrol_codegen() { docker exec relay nfltr-relay machines code --data-dir /var/lib/nfltr-relay "$@"; }
#   enrol NAME CMD...    pipes NAME's code into CMD, which reads it on stdin
# e.g.
#   enrol hub docker exec -i hub nfltr config set-relay relay:8443 \
#       --proxy-url https://relay:8444 --cert-sha256 "$fp" --code-file -
# ENROL_ACCOUNT (default admin) is the account the machine joins; empty: its
# own account. An account is its first machine: until a machine of
# that name exists, the relay refuses codes for it, so enrol first enrols
# CMD as that machine (its own account) and then as NAME (CMD with
# --replace: nfltr config set-relay does not enrol over a good certificate
# without it): the account's root stays in the key file, CMD ends up NAME.
# A harness that redeems the data dir's admin-enrol-code first needs none
# of this.

enrol() { # NAME CMD...
	local name="$1" acct="${ENROL_ACCOUNT-admin}" code err replace=""
	shift
	err="$(mktemp)" # codegen's stderr: its note on success, the refusal's reason
	# A relay logs its fingerprint before its key file and machine CA exist:
	# the code is asked for until it comes (30 s).
	for _ in $(seq 30); do
		if [[ -n "${acct}" ]]; then
			code="$(enrol_codegen --name "${name}" --account "${acct}" 2>"${err}")" || {
				# no machine roots the account yet: CMD enrols as its root first
				grep -q "no such machine in the key file" "${err}" && [[ "${name}" != "${acct}" ]] &&
					ENROL_ACCOUNT="" enrol "${acct}" "$@" && replace=--replace && continue
				code=""
			}
		else
			code="$(enrol_codegen --name "${name}" 2>/dev/null)" || code=""
		fi
		[[ "${code}" == enr_* ]] && break
		sleep 1
	done
	rm -f "${err}"
	[[ "${code}" == enr_* ]] || { echo "enrol: no enrolment code for machine ${name}" >&2; return 1; }
	printf '%s\n' "${code}" | "$@" ${replace} >/dev/null || { echo "enrol: machine ${name} did not enrol" >&2; return 1; }
}

enrol_id() { # machine.json on stdin: the relay machine id it was enrolled as
	sed -n 's/.*"machine_id": *"\(m-[a-z2-7]*\)".*/\1/p' | head -1
}
