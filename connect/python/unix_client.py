#!/usr/bin/env python3
"""A connect: mapping's unix socket is a plain socket (stdlib only).

Usage: unix_client.py <socket-path> [payload]

Sends payload, half-closes, prints the answer. A remote that is offline
shows as a connection the sidecar closes at once (and an error event in
nfltr up's log), never as a hang.
"""
import socket
import sys


def main() -> int:
    path = sys.argv[1]
    payload = (sys.argv[2] if len(sys.argv) > 2 else "hello").encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(30)
        s.connect(path)
        s.sendall(payload)
        s.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            b = s.recv(65536)
            if not b:
                break
            chunks.append(b)
    print(b"".join(chunks).decode(errors="replace"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
