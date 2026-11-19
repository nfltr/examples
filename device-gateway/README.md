# A small device through a gateway

A microcontroller, a sensor or a PLC on a home or factory LAN, reached from
anywhere with no code on the device: a gateway on the same LAN (a
Raspberry Pi, a router, any Linux box) runs `nfltr up` with one `forward:`
service per device port, and clients reach those services by name or over
an `nf1…` address, end to end encrypted to the gateway. The guide is
https://nfltr.xyz/docs.
`make device-gateway` (docker, no internet) judges every
claim below by exit codes into `results.json`.

| Path | What it is |
|---|---|
| `device/main.go` | The device stand-in: HTTP on 80, a raw TCP socket on 7 (echo), UDP on 5683 (echo), a maintenance port on 23 that is not published. No nfltr. Also the test's UDP client (`device udp ADDR MSG`). |
| `gateway/gateway.yaml` | The gateway's `nfltr up` config: `ui`, `sensor`, `coap` end to end encrypted for group `ops`, `ui-link` under a capability address. |
| `gateway/relay.env` | The test's private relay; with the hosted relay, `nfltr config login` replaces it. |
| `test/compose.yaml` | The machines: `device` on the LAN only, `gateway` on the LAN and outside, `relay`, `client` outside with no route to the LAN. |
| `../scripts/test-device-gateway.sh` | The run and its checks. |

The client holds three configs: `ops` (organisation group `ops`), `eve`
(group `guest`) and `none` (no certificate).

| Check | Exit |
|---|---|
| ops reaches the device's web UI by name (`nfltr cat pipe gw.plant/ui`) | 0 |
| ops reaches the raw TCP socket (`gw.plant/sensor`) | 0 |
| ops reaches the UDP socket through `nfltr cat forward --udp gw.plant/coap` | 0 |
| a machine with no account reaches the web UI over the nf1 address (`--address-file`) | 0 |
| the same machine by name, with no certificate | 2 |
| the device's maintenance port (not a service) | 3 |
| a machine of group `guest` | 10 |
| the device stopped: the web UI does not answer; started again: it answers with no action | |
| the gateway restarted: name, address and UDP answer again with no action | |

`results.json` holds every check's exit and `recovery_s`: the seconds from
the first try until the device's web UI answered again after the device's
restart and after the gateway's.
