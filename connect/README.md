# Connect sidecar examples

Applications reaching a remote service through nfltr with no SDK: a child
`nfltr cat pipe` process, or a local endpoint of `nfltr up`'s `connect:`
mappings. Guides (the connect sidecar, gRPC over it):
https://nfltr.xyz/docs. There is no automated test here: run a service
machine with `nfltr up` (below), the client machine's sidecar with
`nfltr up -c app.yaml`, and the clients against it. Install nfltr on both
machines with `curl -fsSL https://nfltr.xyz/install.sh | sh`.

## Set up

On the service's machine (`home`, with a service on port 7000 and a gRPC
service on 50051):

```
cat > home.yaml <<'EOF'
agent: home
services:
  upper: { tcp: 7000, e2ee: false }
  grpc:  { tcp: 50051, e2ee: false }
EOF
nfltr up -c home.yaml
```

`e2ee: false` keeps these sessions plain (the hosted relay makes a
service that states nothing end-to-end encrypted). End-to-end encryption
is organisation mode: enrol both machines in your organisation (`nfltr org
join`, https://nfltr.xyz/docs), set `e2ee: true` and `allow_group:
[<the client's group>]` on each service; the client machine's mappings and
dials are then end to end encrypted with no further setting (`plain: true`
on a mapping, `NFLTR_PLAIN=1` for the dial clients, reaches a plain service
on purpose).

On the client machine:

```
mkdir -p -m 700 "$XDG_RUNTIME_DIR/nfltr"     # or any directory only you can write
cat > app.yaml <<EOF
connect:
  upper: { target: home/upper, listen: "unix:$XDG_RUNTIME_DIR/nfltr/upper.sock" }
  grpc:  { target: home/grpc,  listen: "unix:$XDG_RUNTIME_DIR/nfltr/grpc.sock" }
  grpct: { target: home/grpc,  listen: "127.0.0.1:50051" }
status: "127.0.0.1:7801"
EOF
nfltr up -c app.yaml --log-format json
```

## Python (`python/`)

```
python3 python/dial_client.py home/upper hi            # nfltr cat pipe as a subprocess
python3 python/unix_client.py "$XDG_RUNTIME_DIR/nfltr/upper.sock" hi
pip install grpcio
python3 python/grpc_unix_client.py "unix://$XDG_RUNTIME_DIR/nfltr/grpc.sock"   # prints SERVING
curl -s http://127.0.0.1:7801/status
```

`NFLTR` names the nfltr binary when it is not on `PATH`.

## .NET (`csharp/`, .NET 8)

```
dotnet run --project csharp/DialClient -- home/upper hi
dotnet run --project csharp/GrpcClient -- unix:$XDG_RUNTIME_DIR/nfltr/grpc.sock
dotnet run --project csharp/GrpcClient -- localhost:50051
```

On Windows, map the service to a named pipe instead
(`listen: "pipe:nfltr-grpc"`) and run
`dotnet run --project csharp/GrpcClient -- pipe:nfltr-grpc`. DialClient
puts `nfltr cat pipe` in a Job Object that kills it when the .NET process
exits, reads the session as binary streams and stderr asynchronously.

A complete .NET fleet (control plane and edge agents, both gRPC call
shapes, E2EE in organisation mode, rollout) built on these patterns: `../dotnet-fleet/`.

The clients expect these services on `home`: `upper` reads to EOF and
answers in upper case, `grpc` serves the standard gRPC health check.
