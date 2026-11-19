#!/usr/bin/env python3
"""A grpcio client reaching a remote gRPC service through a connect: mapping.

Usage: grpc_unix_client.py unix:///run/user/1000/nfltr/ledger.sock
   or: grpc_unix_client.py localhost:50051

The only change from talking to the service directly is the target. This
calls the standard health check (grpc.health.v1.Health/Check) with
hand-encoded bytes so it needs no generated code: an empty request asks for
the server's overall health; b"\\x08\\x01" is SERVING.

  pip install grpcio
"""
import sys

import grpc


def main() -> int:
    target = sys.argv[1]
    # Loopback and a user-only socket: plaintext is local only. The relay
    # sees the bytes unless the server uses TLS (grpc.ssl_channel_credentials
    # and the server's own name as grpc.default_authority).
    with grpc.insecure_channel(target) as channel:
        check = channel.unary_unary(
            "/grpc.health.v1.Health/Check",
            request_serializer=lambda b: b,
            response_deserializer=lambda b: b,
        )
        try:
            resp = check(b"", timeout=10)
        except grpc.RpcError as e:  # UNAVAILABLE at once when the remote is offline
            print(f"rpc failed: {e.code().name}: {e.details()}", file=sys.stderr)
            return 1
    print("SERVING" if resp == b"\x08\x01" else f"status bytes {resp!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
