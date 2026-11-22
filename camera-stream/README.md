# A camera's stream

An IP camera (or a media server) on machine A's network, played on machine
B. RTSP runs over one TCP connection when the player asks for it, and
nfltr serves the camera's RTSP port under an nf1 address: B needs the
`nfltr` command and the address file, no account, and the camera is
reachable from A's network only. The session is end to end encrypted
between the two machines; the relay sees neither the address's secret nor
the video. `make camera-stream` runs it with an RTSP server fed a test
pattern and judges every claim below by exit codes.

## Run it

On machine A, enrolled in your account (`nfltr config login`), on the
camera's network (here the camera at `192.168.1.50`, RTSP on port 554):

```console
a$ nfltr cat serve camera --forward 192.168.1.50:554 --agent camera-box --address --address-file camera.addr
```

Copy `camera.addr` to machine B over a channel you trust, then on B:

```console
b$ chmod 600 camera.addr
b$ nfltr cat forward --address-file camera.addr --listen 127.0.0.1:18554
b$ ffplay -rtsp_transport tcp rtsp://127.0.0.1:18554/stream
```

The player asks for the video over RTSP's TCP connection:
`-rtsp_transport tcp` for ffmpeg's tools, "Use RTP over RTSP (TCP)" in
VLC's preferences. The path after the port (`/stream`) and any user and
password are the camera's own. The address lives in a file of mode 0600 on
both machines; `nfltr cat serve ... --new-address` revokes it.

## What the test checks

`make camera-stream` (`scripts/test-camera-stream.sh`) runs machine A
(MediaMTX on A's loopback, RTSP over TCP only, fed a 640x360 H.264 test
pattern by ffmpeg), machine B and a private relay as containers; A and B
share no network, only the relay sits on both.

| Check | Passes when |
|---|---|
| `h264-640x360` | ffprobe on B through the address reads one H.264 video stream, 640x360 |
| `frame` | ffmpeg on B saves a frame of it |

Not run: a real camera; the test pattern stands in for one.

| Path | What it is |
|---|---|
| `test/compose.yaml` | The camera (MediaMTX and ffmpeg), `a` (the serve), `b` (the forward), on `scripts/lib/nf1/compose.yaml`'s machines and relay |
| `test/Dockerfile` | The machines' image: MediaMTX with ffmpeg, by digest |

`CAMERA_STREAM_OUT` names the evidence directory (default: a new
directory under `$TMPDIR`): `checks.jsonl`, `checks.log`, `stream.txt`,
the saved frame (`run/b/frame.png`) and the containers' logs.
