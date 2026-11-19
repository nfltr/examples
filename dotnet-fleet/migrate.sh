#!/usr/bin/env bash
set -euo pipefail

# Adding nfltr to the app as a patch: a copy of app/ with migration.patch
# applied is with-nfltr/, file for file (proto/ and common/, the protocol
# and the business logic, are shared and do not change).
#
#   migrate.sh <dir>     copy app/ to <dir>, apply migration.patch there,
#                        check the result is with-nfltr/, print `git diff --stat`
#                        and one JSON line: {"apply_ms":...,"files":...}
#   migrate.sh --update  regenerate migration.patch from app/ and with-nfltr/
# Build outputs (bin/, obj/) are never part of either side.

EX="$(cd "$(dirname "$0")" && pwd)"
PATCH="${EX}/migration.patch"
copy() { # src dst: the tree without build outputs
    mkdir -p "$2"
    (cd "$1" && find . -type f ! -path '*/bin/*' ! -path '*/obj/*' -print) | while IFS= read -r f; do
        mkdir -p "$2/$(dirname "$f")"
        cp "$1/$f" "$2/$f"
    done
}
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

if [[ "${1:-}" == --update ]]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' EXIT
    copy "${EX}/app" "${tmp}/app"
    copy "${EX}/with-nfltr" "${tmp}/with-nfltr"
    rc=0
    (cd "${tmp}" && git diff --no-index --no-color app with-nfltr) >"${PATCH}" || rc=$?
    (( rc == 1 )) || { echo "git diff --no-index exited ${rc}" >&2; exit 1; }
    echo "wrote ${PATCH}"
    exit 0
fi

dst="${1:?usage: migrate.sh <dir> | --update}"
[[ ! -e "${dst}" ]] || { echo "${dst} exists" >&2; exit 2; }
copy "${EX}/app" "${dst}"
t0="$(now_ms)"
(cd "${dst}" && git apply -p2 --whitespace=nowarn "${PATCH}")
apply_ms=$(( $(now_ms) - t0 ))
diff -r -x bin -x obj "${dst}" "${EX}/with-nfltr" >/dev/null || {
    echo "app/ + migration.patch is not with-nfltr/: run $0 --update" >&2
    diff -r -x bin -x obj "${dst}" "${EX}/with-nfltr" >&2 || true
    exit 1
}
# from inside the copy: in a repository git apply skips paths outside the current directory
(cd "${dst}" && git apply -p2 --stat "${PATCH}")
files="$(cd "${dst}" && git apply -p2 --numstat "${PATCH}" | wc -l | tr -d ' ')"
echo "{\"apply_ms\":${apply_ms},\"files\":${files}}"
