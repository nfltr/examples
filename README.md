<p align="center"><img src="docs/logo.svg" width="96" alt="nfltr"></p>

# nfltr examples

Working examples of [nfltr](https://nfltr.xyz): each one a setup you can
copy, with an end-to-end test that runs it in containers against the
**released** `nfltr` and `nfltr-relay` and judges every check by exit code.

| Example | What it shows | Test |
|---|---|---|
| [device-gateway](device-gateway/) | A small device on a LAN (no nfltr on it) reached through a gateway | `make device-gateway` |
| [dotnet-fleet](dotnet-fleet/) | nfltr added to your own .NET 8 gRPC fleet, through the connect sidecar | `make dotnet-fleet` |
| [gpu-box](gpu-box/) | A model server on a home GPU box, used from a laptop elsewhere | `make gpu-box` |
| [home-assistant](home-assistant/) | Home Assistant reachable from anywhere with no inbound port | `make home-assistant` |
| [pihole](pihole/) | A home Pi-hole as a laptop's resolver away from home | `make pihole` |
| [reverse-proxy](reverse-proxy/) | Caddy or Traefik serving the public through `nfltr up` | `make reverse-proxy` |
| [connect](connect/) | Python and .NET clients of the connect sidecar | — |

## Running the tests

Needs Docker, openssl, python3 and Go (the version in `go.mod`; the go
command fetches it).

```bash
make gpu-box                    # one example
make check                      # go vet and build, then every example
NFLTR_VERSION=vX.Y.Z make pihole   # against a given release (default: the latest)
```

Each test fetches the released binaries for Linux through
[install.sh](https://nfltr.xyz/install.sh), which checks their signature
and checksum, and starts a private relay in a container: nothing reaches a
hosted service. A run writes its evidence (logs, every check's exit code,
`results.json`) to a temporary directory it names. Run the examples one at
a time on a Docker host (no `make -j`).

## Install nfltr

```bash
curl -fsSL https://nfltr.xyz/install.sh | sh                    # nfltr
curl -fsSL https://nfltr.xyz/install.sh | sh -s -- --with relay  # and nfltr-relay
```

Documentation: https://nfltr.xyz/docs

## License

Apache-2.0, see [LICENSE](LICENSE).
