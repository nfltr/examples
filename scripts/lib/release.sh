# scripts/lib/release.sh: the released nfltr and nfltr-relay, as a user gets
# them. Sourced by bash (3.2 too).
#   release_bins DIR ARCH   linux/ARCH binaries into DIR through install.sh
#                           (its signature and checksum checks), whatever the
#                           host: a uname shim names Linux and ARCH to it.
# NFLTR_VERSION pins a release (default: the latest); NFLTR_INSTALL_URL
# overrides the installer's address.

release_bins() { # DIR ARCH
	local shim rc=0
	shim="$(mktemp -d)"
	printf '#!/bin/sh\ncase "$1" in -m) echo %s ;; *) echo Linux ;; esac\n' "$2" >"${shim}/uname"
	chmod +x "${shim}/uname"
	curl -fsSL "${NFLTR_INSTALL_URL:-https://nfltr.xyz/install.sh}" |
		PATH="${shim}:${PATH}" NFLTR_INSTALL_DIR="$1" sh -s -- --with relay >"${shim}/install.log" 2>&1 || rc=$?
	[ "${rc}" = 0 ] || cat "${shim}/install.log" >&2
	rm -rf "${shim}"
	return "${rc}"
}
