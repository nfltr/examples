#!/usr/bin/env python3
"""One session to a remote service through `nfltr cat pipe` (stdlib only).

Usage: dial_client.py <agent>/<service> [payload]

Writes payload (default "hello") to the session, half-closes it (stdin EOF),
prints the remote's answer from stdout and each JSON event from stderr, and
exits with dial's exit status (0 ok, 2 auth, 3 not_found, 5 unreachable,
7 e2ee_pin_mismatch, 10 e2ee_client_refused, ...). On a machine enrolled in
an organisation (nfltr org join) the session is end-to-end encrypted in
organisation mode; NFLTR_PLAIN=1 opens it plain on purpose (cat pipe --plain).
"""
import json
import os
import subprocess
import sys
import threading


def main() -> int:
    target = sys.argv[1]
    payload = (sys.argv[2] if len(sys.argv) > 2 else "hello").encode()
    nfltr = os.environ.get("NFLTR", "nfltr")
    plain = os.environ.get("NFLTR_PLAIN") == "1"
    proc = subprocess.Popen(
        [nfltr, "cat", "pipe", target, "--exit-with-parent", *(["--plain"] if plain else [])],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        bufsize=0,  # binary, unbuffered: the session's bytes
    )
    events = []

    def read_events() -> None:  # read stderr concurrently: a full pipe blocks dial
        for line in proc.stderr:
            events.append(json.loads(line))

    t = threading.Thread(target=read_events)
    t.start()
    proc.stdin.write(payload)
    proc.stdin.close()  # half close: the remote reads EOF, its answer still comes
    answer = proc.stdout.read()
    code = proc.wait()
    t.join()
    for e in events:
        print("event:", json.dumps(e), file=sys.stderr)
    sys.stdout.write(answer.decode(errors="replace") + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
