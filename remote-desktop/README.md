# A remote desktop

A desktop on machine A shown in a VNC viewer on machine B. Screen sharing
is one TCP port (5900 for VNC; macOS Screen Sharing is a VNC server,
Windows Remote Desktop uses 3389), and nfltr serves that port under an nf1
address: B needs the `nfltr` command and the address file, no account.
The session is end to end encrypted between the two machines; the relay
sees neither the address's secret nor the screen. `make remote-desktop`
runs it with a Linux desktop in a container and judges every claim below
by exit codes.

## Run it

On machine A, enrolled in your account (`nfltr config login`), with a VNC
server listening on its loopback (x11vnc with `-localhost`, or macOS Screen
Sharing turned on in System Settings, General, Sharing):

```console
a$ nfltr cat serve desktop --forward 127.0.0.1:5900 --address --address-file desktop.addr
```

Copy `desktop.addr` to machine B over a channel you trust, then on B:

```console
b$ chmod 600 desktop.addr
b$ nfltr cat forward --address-file desktop.addr --listen 127.0.0.1:15900
```

A VNC viewer on B connects to `127.0.0.1:15900` (on a Mac, `open
vnc://127.0.0.1:15900`; a port other than 5900 avoids B's own screen
sharing). For Windows Remote Desktop, A forwards `127.0.0.1:3389` and B's
client connects to `127.0.0.1:13389`. The VNC server still asks for its
password (and macOS for the Mac's login): the address only gets the viewer
to the login. The address lives in a file of mode 0600 on both machines;
`nfltr cat serve ... --new-address` revokes it.

## What the test checks

`make remote-desktop` (`scripts/test-remote-desktop.sh`) runs machine A
(Xvfb, an xterm and x11vnc on A's loopback, its password random per run),
machine B and a private relay as containers; A and B share no network,
only the relay sits on both. B's viewer is `test/probe`, an RFB client
(RFC 6143) with VNC authentication.

| Check | Passes when |
|---|---|
| `full-frame` | with the password, the viewer completes the handshake, reads a 1024x640 desktop named `machine A` and a full raw frame (2,621,440 bytes) |
| `wrong-password` | with a wrong password the server refuses it |

Not run: macOS Screen Sharing and Windows Remote Desktop; both are TCP
services on one port, as the VNC server here is.

| Path | What it is |
|---|---|
| `test/compose.yaml` | The desktop (Xvfb, xterm, x11vnc), `a` (the serve), `b` (the forward), on `scripts/lib/nf1/compose.yaml`'s machines and relay |
| `test/Dockerfile` | The machines' image: Alpine with Xvfb, x11vnc and xterm |
| `test/probe/` | B's VNC viewer |

`REMOTE_DESKTOP_OUT` names the evidence directory (default: a new
directory under `$TMPDIR`): `checks.jsonl`, `checks.log`, `desktop.json`
and the containers' logs.
