# BSFChat Deployment

Production docker-compose setup for running BSFChat on your own server.

There is exactly one file you edit: **`.env`**. Everything under `config/`
and `nginx/` is generated from it by `./setup.sh`. That is deliberate — the
chat server and the TURN relay share a secret, and a self-host that half
works because two files drifted apart is worse than one that refuses to
start.

## Quick Start

```bash
# 1. Copy this directory to your server
scp -r deploy/ user@your-server:/opt/bsfchat/
cd /opt/bsfchat

# 2. Fill in your settings
cp .env.example .env
$EDITOR .env          # CHAT_HOST, ID_HOST, TURN_HOST, TURN_EXTERNAL_IP

# 3. Generate the config (also generates the TURN secret)
./setup.sh

# 4. Start
docker compose up -d
```

`./setup.sh --check` re-validates `.env` and the generated files without
writing anything. Re-run `./setup.sh` after **any** change to `.env`.

### The two settings people get wrong

- **`TURN_EXTERNAL_IP`** — your public IPv4 (`curl -4 https://ifconfig.me`).
  Almost every VPS puts the guest behind a 1:1 NAT, so without this coturn
  advertises a private address as the relay candidate and every relayed call
  fails. There is no error anywhere: the allocation succeeds, the media goes
  nowhere. `setup.sh` refuses to run without it.
- **`CHAT_HOST`** — becomes the Matrix server name, and therefore part of
  every user ID (`@you:chat.example.com`). Changing it later invalidates
  existing accounts. Decide before your first start.

## What's Running

| Service | Address | Notes |
| --- | --- | --- |
| `bsfchat-server` | `127.0.0.1:8448` | chat server |
| `bsfchat-identity` | `127.0.0.1:8480` | OIDC identity provider + web UI |
| `bsfchat-coturn` | host network, `3478` | STUN/TURN relay for voice |

Both HTTP services bind to loopback only — put a reverse proxy in front.
coturn is the exception: it must be reachable directly, and must never be
proxied (TURN is not HTTP).

There is no object-storage service. Media is stored on disk in
`data/server/media/`, which is the right default for a self-hosted server:
one fewer daemon to run, patch and back up. If you would rather use
S3-compatible storage, uncomment the `[storage.s3]` block in
`config/server.toml.template`, set `type = "s3"`, re-run `./setup.sh`, and
bring your own endpoint.

## Reverse Proxy

`./setup.sh` renders `nginx/bsfchat.conf` with your domains filled in:

```bash
sudo cp nginx/bsfchat.conf /etc/nginx/sites-available/bsfchat
sudo ln -s /etc/nginx/sites-available/bsfchat /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

**Read the header comment in that file before you go live.** As generated it
listens on port 80 only, which is fine while you obtain a certificate and not
fine afterwards. If you terminate TLS at Cloudflare with SSL/TLS mode
"Flexible", the CDN-to-origin leg is plaintext HTTP across the public
internet — every message, media upload and access token readable by anyone
on that path. Get a certificate on the origin:

```bash
sudo certbot --nginx -d chat.example.com -d id.example.com
```

then uncomment the TLS blocks and the `return 301` redirects in the file, and
set Cloudflare to **Full (strict)**.

Two proxy settings are load-bearing and are generated from `.env` so they
cannot drift:

- `proxy_read_timeout 330s` — the server allows `/sync` long-polls up to
  300s (`kMaxSyncTimeoutMs`). A shorter proxy timeout cuts them mid-poll and
  clients see constant reconnects.
- `client_max_body_size` — derived from `MAX_UPLOAD_MB`, with a little
  headroom so an oversized upload is rejected by the server (proper JSON
  error) rather than by nginx (bare HTML 413).

### Sizing the worker pool

`workers` in `config/server.toml` counts concurrent **connections**, not
concurrent requests, and it is the one setting that stalls the whole server
rather than merely slowing it down when set too low.

cpp-httplib runs an entire connection on one pool thread and holds that thread
until the socket closes. `/sync` is a long poll that deliberately keeps its
socket open, so every signed-in client parks a thread for the length of its
poll — and holds further sockets for its voice poll, media and identity
fetches. Budget roughly **4 connections per simultaneously connected client**.

The default is 64 base threads with a ceiling of 512, which carries a
ten-client deployment with room to spare. A thread parked on a long poll costs
a stack and nothing else, so over-sizing this is far cheaper than
under-sizing it.

This mattered in practice: at the old default of `workers = 4`, two desktop
clients were enough to hold every thread, and a message send then sat in the
queue with nothing to run it until a long poll timed out. Measured on
loopback, delivery went from 81 ms to **28.4 s**. If message delivery is
erratic and the server is otherwise idle, this is the first thing to check.

`max_workers` is a burst safety net rather than the mechanism: httplib only
grows the pool when it sees zero idle threads at the instant a connection
arrives, and the thread it spawns picks up the oldest queued connection rather
than the one that triggered it. `workers` has to carry the steady load on its
own.

### Media ranges

Media downloads support HTTP Range and stream in 64 KB chunks, so a range
request costs its own size in memory rather than the size of the object. `HEAD`
works and reads nothing from storage.

One deviation worth knowing before you put a CDN in front of this: **a single
`Range` header may ask for at most 4 ranges.** More than that is answered `416`
with `Content-Range: bytes */<size>`, not served. Each range in a
`multipart/byteranges` response is a separate storage read, so an unbounded
count is a cheap request-amplification lever; RFC 9110 §14.2 explicitly permits
refusing such a header. Apache and nginx allow considerably more, so a client or
CDN that stitches many small ranges into one request will see `416` here where
it saw `206` there. The cap is a compile-time constant
(`kMaxRangeCount` in `server/src/api/MediaHandler.cpp`), not a config key.

Zero-length uploads are refused with `400`.

Caddy equivalent, if you prefer it:

```
chat.example.com {
    reverse_proxy localhost:8448 {
        transport http { read_timeout 330s }
    }
    request_body { max_size 108MB }
}
id.example.com {
    reverse_proxy localhost:8480
}
```

## Voice Chat

Voice needs STUN and TURN. Without TURN, users behind symmetric NAT or CGNAT
cannot connect at all. The bundled coturn provides both, so no third-party
STUN server is involved and nothing about your calls leaves your box.

`setup.sh` generates the shared secret with `openssl rand -hex 32` and writes
it to `.env`; compose passes it to coturn and renders it into
`config/server.toml`. The server then hands clients short-lived credentials
derived from it (`turn_ttl`, default 3600s) — there is no static TURN
username or password to manage, and no placeholder that "works" until you hit
a real NAT.

### Firewall

```
3478/tcp          STUN/TURN
3478/udp          STUN/TURN
49160-51160/udp   media relay range
```

The relay range genuinely needs to be that wide. WebRTC allocates one relay
port per (peer connection x TURN URI), and two TURN URIs are advertised
(udp + tcp transports), so a full-mesh call of N participants consumes
`N * (N-1) * 2` ports:

| Participants | Relay ports |
| --- | --- |
| 3 | 12 |
| 5 | 40 |
| 10 | 180 |
| 20 | 760 |

A range of a few dozen ports is exhausted by a single small call, after which
allocations fail and calls silently never connect. `total-quota` and
`user-quota` in `config/turnserver.conf.template` stop one client eating the
range.

Adjust with `TURN_MIN_PORT` / `TURN_MAX_PORT` in `.env` — `setup.sh` warns if
you shrink the range below 500 ports, and prints the exact firewall rules to
open.

### Verifying it works

```bash
docker compose logs -f coturn      # look for "relay=<your public IP>"
```

Then place a call between two clients on different networks (not two tabs on
the same LAN — that succeeds via host candidates and tells you nothing about
TURN).

## Data Persistence

Everything lives under `./data/`:

- `data/server/` — `bsfchat.db` and media
- `data/identity/` — `identity.db` and the OIDC RSA signing keys

Both configs use **absolute** `/data/...` paths. A relative path here is a
trap: the container's working directory is not the volume, so the database
lands in the container's writable layer and is destroyed on the next
`docker compose up`. For the identity service that would also regenerate the
RSA signing key and invalidate every issued token.

`data/identity/keys/private.pem` is a real private key. It is covered by
`.gitignore`, but back it up somewhere encrypted — losing it logs everyone
out permanently.

## Updating

```bash
docker compose pull
docker compose up -d
```

That pulls whatever your channel currently points at. Check what you got:

```bash
curl -s http://127.0.0.1:8448/_matrix/client/versions | jq .   # server
curl -s http://127.0.0.1:8480/.well-known/openid-configuration | jq . # identity
docker compose logs server | head -1
```

Both report a version, a revision and the channel they were built on.

## Switching channels

One setting, `BSFCHAT_TAG` in `.env`, applies to both the server and the
identity service — they release together, and a stable server against a
beta identity service is not a combination anyone tests.

| `BSFCHAT_TAG` | Channel | What you get |
| --- | --- | --- |
| `latest` | **stable** | The highest released version. The default. |
| `latest-beta` | **beta** | The highest of stable *or* release candidate. Never behind `latest`. |
| `main` | development | Tip of branch, rebuilt on every push. Unreviewed. |
| `v0.1.0` | pinned | That exact release, forever. |

```bash
$EDITOR .env          # BSFCHAT_TAG=latest-beta
./setup.sh            # prints the channel it rendered
docker compose pull
docker compose up -d
```

`latest` follows the **highest** version, not the most recently published
one. A hotfix cut on an older line gets its own `vX.Y.Z` tag and does not
move `latest`, so a `docker compose pull` can never quietly downgrade you.
`latest-beta` is stable *plus* release candidates, so a new stable release
moves it too. The full rules are in `server/docs/release-channels.md`.

If you run the beta channel, set the desktop client to the beta channel as
well (Settings -> Updates), or testers will be running a stable client
against an RC server.

### Coming from an older install

`latest` used to mean "tip of `main`" — it was pushed on every commit.
It now means the newest stable release, and the old behaviour moved to
`main`.

So if your `.env` says `BSFCHAT_TAG=latest` and predates this change, your
next `docker compose pull` moves you from tip-of-branch to the newest
stable release. That is almost certainly what you want. If you were
deliberately tracking the branch, set `BSFCHAT_TAG=main` before pulling.

`COTURN_TAG` is unaffected: coturn is internet-facing and stays pinned to
an exact version, never to a moving tag.

### Rolling back

Channel tags move forward. To go back, pin the version you know worked:

```bash
$EDITOR .env          # BSFCHAT_TAG=v0.1.0
./setup.sh && docker compose up -d
```

Database schema migrations run forward on start and are **not** reversible,
so rolling the image back does not roll the database back. Take a copy of
`data/` before upgrading anything you cannot afford to lose.

### File ownership

The images run as uid/gid **10001**, not root. `./setup.sh` chowns
`data/server` and `data/identity` to match. If it could not (it says so),
do it yourself:

```bash
sudo chown -R 10001:10001 data/server data/identity
```

Otherwise the containers start, fail to open their database or write their
signing keys, and report a permission error that reads like an application
bug.

## Logs

```bash
docker compose logs -f           # all services
docker compose logs -f server    # just the chat server
```
