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

**`nginx -t` in that third line is load-bearing, and this template has never
been through it.** There is no nginx binary or image on the machine this repo
is developed on, so nothing here parses the rendered file — `./setup.sh`
checks only that every `${...}` was substituted. The equivalent config was
confirmed valid by hand on the production host, so the directives are
known-good in substance; what is untested is this file. The two access-log
`map` regexes were verified separately against PCRE with `perl`, which is the
same engine nginx uses but tells you nothing about whether nginx accepts the
surrounding directives. Treat `nginx -t` as the first real test of this
config, and read its output: `systemctl reload nginx` with a broken config
leaves the old one serving and puts the error in the journal, which from the
outside looks exactly like a reload that did nothing.

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

Two proxy settings are load-bearing:

- `proxy_read_timeout 330s`, on the `/sync` location — the server allows
  `/sync` long-polls up to 300s (`kMaxSyncTimeoutMs`). A shorter proxy
  timeout cuts them mid-poll. Read
  "[Long polls, proxy timeouts, and the ceiling you cannot
  raise](#long-polls-proxy-timeouts-and-the-ceiling-you-cannot-raise)" below
  before you touch it — this is the setting that has already caused an
  outage here, and if you are behind Cloudflare it is not the number that
  decides your real ceiling. It is a literal in the template, **not**
  rendered from `.env`.
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

Caddy equivalent, if you prefer it. Same split as the nginx config: the
long timeout is scoped to the long poll, and everything else keeps a value
where a wedged upstream surfaces quickly.

```
chat.example.com {
    # The long poll. 330s = kMaxSyncTimeoutMs (300s) + margin; must stay
    # above 300s or /sync is cut mid-poll. See "Long polls, proxy timeouts,
    # and the ceiling you cannot raise" above — behind Cloudflare the real
    # ceiling is ~100s no matter what this says.
    @sync path /_matrix/client/v3/sync
    reverse_proxy @sync localhost:8448 {
        transport http { read_timeout 330s write_timeout 330s }
    }

    reverse_proxy localhost:8448 {
        transport http { read_timeout 120s write_timeout 120s }
    }
    request_body { max_size 108MB }
}
id.example.com {
    # No long-poll endpoint here; Caddy's defaults are correct.
    reverse_proxy localhost:8480
}
```

Caddy is not tested here either — the same caveat as `nginx -t` applies, and
`caddy validate` is the equivalent first real check.

## Long polls, proxy timeouts, and the ceiling you cannot raise

**If a client or bot connects fine and then receives nothing, read this
first. It is almost always this.**

### The symptom

A client or bot signs in successfully, reports its rooms correctly, and then
receives no events at all — indefinitely. Messages sent from another client
never arrive. The server log looks clean, because nothing at the server is
wrong. In the *proxy's* log you find periodic `504`s (nginx) or `524`s
(Cloudflare) on `/_matrix/client/v3/sync`, at a suspiciously regular
interval, each carrying an HTML body the client cannot parse and does not
expect.

This happened in production on 2026-09-20. The box was running
`proxy_read_timeout 60s`, hand-edited into
`/etc/nginx/sites-enabled/bsfchat` and never present in this repo. An
integration bot asking for the maximum the protocol permits was blinded for
fifteen minutes while looking, from its own logs, perfectly healthy. The
desktop client was unaffected — not because it was doing anything better,
but because its 30s default happened to be under 60s.

### Why it happens

`/sync` is a **long poll**. The client opens the request and the server
answers nothing, holding the socket, until an event arrives (a condition
variable wakes it within microseconds of the commit) or the timeout the
client asked for expires. The protocol lets a client ask for up to 300s
(`kMaxSyncTimeoutMs`); the default is 30s (`kDefaultSyncTimeoutMs`).

Every hop in front of the server has its own idea of how long a response may
take, and **the smallest number in the chain wins**:

| Hop | Limit | Where it is set |
| --- | --- | --- |
| Client's requested `?timeout=` | up to 300s | the client's own config |
| Chat server's cap | 300s | `kMaxSyncTimeoutMs`, compiled in |
| nginx `proxy_read_timeout` | 330s | `nginx/bsfchat.conf`, `/sync` location |
| **Cloudflare origin pull** | **~100s** | **not settable from nginx** |
| any other CDN / load balancer / corporate proxy | varies | not here |

A hop that gives up does not hand the client a timeout. It hands the client
an HTML error page where a JSON sync response was expected, which is why
this presents as silence rather than as an error.

### The Cloudflare ceiling — for anyone self-hosting behind a CDN

Cloudflare abandons an origin pull after roughly **100 seconds** on every
plan below Enterprise and serves its own `524 A Timeout Occurred` page.
**Nothing in `nginx/bsfchat.conf` changes this.** `proxy_read_timeout`
governs nginx's patience with the chat server; it has no bearing on
Cloudflare's patience with nginx. Raising it to 330s, or to an hour, moves
nothing.

So on a Cloudflare-proxied deployment the real ceiling on a `/sync` poll is
under 100s, not the 300s the protocol advertises — and a client that asks
for 300s *because the protocol says it may* is broken before it starts.
The protocol maximum describes what the server will honour, not what your
deployment can deliver.

**What to do about it:**

- **Keep clients at or below 60s.** The 30s default is fine and costs very
  little: `/sync` is event-driven, so a client is woken the instant an event
  is committed — the timeout only decides how often an *idle* connection is
  re-established. A shorter poll is a few more empty round trips per hour,
  not more latency on messages.
- **Do not raise a client's sync timeout to "reduce reconnects" behind a
  CDN.** Past ~90s you are buying 524s.
- **If you genuinely need the full 300s** — a bot on a metered link, say —
  the chat host has to bypass the CDN proxy. Set that DNS record to
  DNS-only ("grey cloud") and terminate TLS at your own nginx, or move to a
  plan where the ceiling is raisable. A `cloudflared` tunnel does **not**
  buy you more here; it is subject to the same proxy timeouts.

Other CDNs and load balancers have their own ceilings (AWS ALB's idle
timeout defaults to 60s, for instance). The exercise is the same: find the
smallest number in the chain.

### Finding your own ceiling

Measure it, do not assume it. With a valid access token and a current
`since` token, ask for a long poll in a quiet room and time how long you
wait and what comes back:

```bash
TOKEN=...   # a working access token
SINCE=...   # the next_batch from a normal /sync

# Through the CDN, as a client sees it:
curl -s -o /dev/null -w 'http=%{http_code}  after=%{time_total}s\n' \
  -H "Authorization: Bearer $TOKEN" \
  "https://chat.example.com/_matrix/client/v3/sync?since=$SINCE&timeout=120000"

# Straight at the origin, bypassing the CDN entirely:
curl -s -o /dev/null -w 'http=%{http_code}  after=%{time_total}s\n' \
  --resolve chat.example.com:443:ORIGIN_IP \
  -H "Authorization: Bearer $TOKEN" \
  "https://chat.example.com/_matrix/client/v3/sync?since=$SINCE&timeout=120000"
```

Reading the result:

| What you see | What it means |
| --- | --- |
| `http=200 after=120s` | Healthy. The poll ran its full budget and returned an empty sync. |
| `http=504` at ~60s, both requests | nginx is cutting it. Your installed config is not this repo's — see below. |
| `http=524` at ~100s, CDN only; origin fine | The Cloudflare ceiling. Expected. Lower your clients' timeout. |
| `http=502` immediately | The chat server is down or not listening on 8448. A different problem. |

The 504-vs-524 distinction is the whole diagnosis: a 504 is *your* proxy
giving up on the server, a 524 is *Cloudflare* giving up on your proxy.

### Check what is actually installed

The production incident was not a wrong value in this repo. This repo has
had `330s` since configs were first rendered from `.env`. It was a
**hand-edit on the box** that no one diffed against the source for months.
Nothing in nginx warns you about this; a config that only exists on the
server is a config no one reviews.

After any change, and periodically:

```bash
# Is what is installed what this repo renders?
./setup.sh                                                  # re-render
sudo diff -u /etc/nginx/sites-enabled/bsfchat nginx/bsfchat.conf

# What timeouts is the running nginx actually configured with?
sudo nginx -T 2>/dev/null | grep -nE 'proxy_(read|send)_timeout|client_max_body_size'
```

`nginx -T` (capital T) dumps the *whole* effective configuration including
every include, which is the only way to catch a value set in `nginx.conf`
or a snippet rather than in this file. If `diff` reports anything, decide
which side is right and then fix the *template*, not the box — otherwise
the next `./setup.sh` reinstates the bug, or the next person re-fixes it.

`./setup.sh` now warns when the installed file differs from what it just
rendered.

### The other nginx default that dislikes long polls

`worker_connections` is set in `nginx.conf`, not in the file this repo
renders, and Debian and Ubuntu ship it at **768**. A parked `/sync` poll
holds *two* connection slots — one facing the client, one facing the chat
server — so the practical ceiling is about `worker_connections / 2` per
worker process. A normal web workload never approaches that. This one parks
connections on purpose.

Above a few hundred simultaneous clients per worker process, raise it:

```nginx
events {
    worker_connections 4096;
}
```

and raise the nginx user's file-descriptor limit to match
(`LimitNOFILE` in the unit, or `worker_rlimit_nofile`) — a
`worker_connections` above the fd limit does not give you more capacity, it
just fails differently. The symptom to watch for in `error.log` is
`768 worker_connections are not enough`.

This is separate from, and additional to, `workers` in `config/server.toml`
(see "Sizing the worker pool") — nginx's ceiling and the chat server's
thread pool are two independent limits on the same long polls, and both have
to be sized for the client count.

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
out permanently. `./backup.sh` includes it.

### Nothing here is encrypted at rest

`data/server/bsfchat.db` holds every message ever sent on this server in
plaintext. So does the full-text search index inside it, which keeps a second
copy of every message body. So do the audit log and the queued push payloads.
`data/identity/` holds the OIDC RSA signing key, which mints tokens for any
account on the server.

There is no database passphrase and no disk-level encryption in this stack.
Anyone who can read `data/` can read the entire server, and that is the threat
this section is about: a stolen volume snapshot, an unencrypted backup, a
second administrator, a support engineer at your VPS provider.

What this deployment does do about it:

| | |
| --- | --- |
| Directories | `./setup.sh` sets `data/`, `data/server/` and `data/identity/` to `0750`, owned by the container uid. |
| Database files | The server chmods `bsfchat.db` and its `-wal`/`-shm` siblings to owner-only on **every start**, and logs a warning if it cannot. `./setup.sh` does the same for files left `0644` by an older image. |
| Deleted data | `PRAGMA secure_delete` is on, so deletes overwrite rather than just unlink. A one-time `VACUUM` at first start on this version discards free pages left by older deletes — see "First start after upgrading" below. |
| Backups | `./backup.sh` writes `0600` and tells you to encrypt before the archive leaves the host. |

What it does not do, and what to do instead: if the host's disk is not
encrypted, encrypt it — LUKS on the volume, or a provider-side encrypted
volume — because that is the control that actually covers all of the above at
once, including swap and the WAL. Do that before you decide you need an
encrypted database.

### First start after upgrading to this version

The first time the server starts against an existing database on this release,
it runs a one-time `VACUUM` before it begins serving. This rewrites the
database file to discard free pages, which on a database created by an older
build still contain data that was deleted precisely because it was sensitive:
plaintext access tokens dropped by schema migration v7, pre-redaction message
bodies, and the call-signalling rows that migration v17 deleted because they
carry participants' LAN and public IP addresses. SQLite unlinked those rows; it
did not overwrite them, and `strings bsfchat.db` still finds them.

It logs what it is doing and how long it took. Expect roughly a second per
gigabyte, once, and make sure there is free disk space roughly equal to the
size of the database — `VACUUM` builds the new file alongside the old one. If
it fails (almost always for want of space) the server logs an error and starts
anyway, and retries on the next start.

To skip it on a database too large for the available headroom, set the marker
by hand before starting and run the `VACUUM` yourself during a maintenance
window:

```bash
sqlite3 data/server/bsfchat.db \
  "INSERT OR REPLACE INTO server_meta (key, value) VALUES ('maintenance.freelist_vacuumed','1');"
```

**Any backup taken before this runs still contains all of it.** Rotate old
archives out; that is part of the fix, not an optional extra.

### Two settings worth checking on an existing deployment

Both live in `config/server.toml`, which is regenerated from
`config/server.toml.template` whenever you run `./setup.sh` — so the ordinary
fix for both is to re-run it. If you edited `config/server.toml` by hand, check
these two directly.

**`password_hash_cost`.** Older versions of this template shipped `12`. That is
an exponent: 2^12 = 4,096 PBKDF2-HMAC-SHA256 iterations, which is 128x weaker
than the `19` shipped now and weaker still than the identity service's 600,000
in the same compose file. At 4,096, anyone who obtains `bsfchat.db` cracks
every password in a wordlist at GPU speed.

Raising it is safe and needs no coordination with your users: every stored hash
records the cost it was created with, so old hashes keep verifying, and the
server re-derives each one at the new cost the next time that user logs in
successfully. Nobody is locked out and no password reset is required. The
server warns on every start while the value is below 19.

The one thing to know is the cost side: a login goes from ~2ms of CPU to
150-300ms on a small VPS. That is the point — it is the same 128x tax on an
attacker guessing offline — but if your whole user base signs in at once after
a restart, the server does more work than it used to.

**`trusted_proxies`.** The shipped default used to be loopback only. nginx runs
on the *host* and reaches the container through the published
`127.0.0.1:8448` port, so the peer address the server sees is the Docker
bridge gateway (`172.x.0.1`), not loopback — and the server correctly ignores
`X-Forwarded-For` from a peer it does not trust. The result was that every
client looked like the same address: one shared rate-limit bucket on `/login`
and `/register`, so one person retrying a bad password locked the whole server
out of signing in.

The template now ships:

```toml
trusted_proxies = ["127.0.0.0/8", "::1", "172.16.0.0/12"]
```

`172.16.0.0/12` is safe here only because the container port is published on
`127.0.0.1` — nothing off this machine can reach the server from that range, so
nothing off this machine can present a forged `X-Forwarded-For` that is
believed. If you front the server with something else — a proxy on another host,
or a container on a user-defined network — replace that entry with the proxy's
actual address. Never `0.0.0.0/0`: that lets any client pick its own rate-limit
bucket and the limiter stops existing.

### Behind Cloudflare

This section is about client IP addresses. Cloudflare also imposes a
**~100 second ceiling on `/sync` long polls** that nothing in your nginx
config can raise — if clients connect and then go silent, that is the other
section: "[Long polls, proxy timeouts, and the ceiling you cannot
raise](#long-polls-proxy-timeouts-and-the-ceiling-you-cannot-raise)".

Cloudflare terminates TLS at an edge node, so `$remote_addr` at nginx is a
Cloudflare address on every request and `$proxy_add_x_forwarded_for` appends
it. The chat server reads the rightmost hop it is willing to believe, which
means that unless it trusts the Cloudflare edge, **every user is one client**
and the first person to fail a password enough times locks the whole server out
of `/login`. It is the same failure as the Docker-bridge one above, one hop
further out.

Two ways to fix it. They are not equivalent.

**Preferred: resolve the real client at nginx.** `nginx/bsfchat.conf.template`
carries a commented `set_real_ip_from` / `real_ip_header CF-Connecting-IP`
block. Uncomment it and nginx rewrites `$remote_addr` to the real client before
it builds `X-Forwarded-For`, so the chat server only ever has to trust nginx —
`trusted_proxies` stays at loopback plus the bridge and nothing public is
trusted at all. The Cloudflare range list then lives in one file instead of
two, and the access log stops recording a Cloudflare address for every request.

`set_real_ip_from` is only sound while the origin cannot be reached except
through Cloudflare. Pair it with an origin firewall that accepts only
Cloudflare's ranges (or a `cloudflared` tunnel) and Authenticated Origin Pulls
— otherwise anyone who finds the origin IP, or routes to it through their own
Cloudflare zone, can set `CF-Connecting-IP` themselves.

**Alternative: trust the edge in the chat server.** Put Cloudflare's published
ranges in `trusted_public_proxies`, not `trusted_proxies`, and say why:

```toml
trusted_proxies = ["127.0.0.0/8", "::1", "172.16.0.0/12"]
trusted_public_proxies = [
  "173.245.48.0/20", "103.21.244.0/22", "162.158.0.0/15", "104.16.0.0/13",
  # ...the rest of cloudflare.com/ips-v4 and ips-v6
]
trusted_public_proxies_reason = "Cloudflare edge, refreshed 2026-09-20"
```

The two keys are one trust list, not two — entries in either are trusted
identically and you must not repeat them. What the separate key does is record
that you meant it. The server warns at startup about any range reaching outside
loopback and the private ranges that is **not** written under
`trusted_public_proxies`, so a public range added later is still called out; and
it warns about a range too wide to be an edge fleet (`0.0.0.0/0`, `::/0`, a
public `/8`) whichever key it is in. A `trusted_public_proxies` list with an
empty reason is also still warned about. What you get on a correct
CDN-fronted config is one `info` line at boot naming the ranges and the reason
— which is worth reading, because diffing it across restarts is how you see the
list change.

Before v0.0.49 there was no second key and the server logged one warning per
public range, which on a Cloudflare-fronted deployment meant a screenful of
correct warnings on every boot. Moving the ranges from `trusted_proxies` to
`trusted_public_proxies` is the upgrade step; nothing breaks if you don't, you
just keep getting told (once, now, rather than per range).

### Keeping the Cloudflare list current

Whichever of the two you pick, **nothing fetches the list for you.** The server
ships no built-in copy on purpose: a list compiled into a release is wrong in
both directions the moment Cloudflare changes it — blessing ranges they have
given up, warning about ones they have just added — and it would put a third
party in charge of whose `X-Forwarded-For` your rate limiter believes.

Refresh by hand from <https://www.cloudflare.com/ips-v4> and
<https://www.cloudflare.com/ips-v6>, and move the date in
`trusted_public_proxies_reason` (or the comment in the nginx block) along when
you do. Out of date in each direction:

* **Cloudflare adds a range you do not have.** Clients arriving through those
  edge nodes share one rate-limit bucket. The symptom is the server's runtime
  warning that `X-Forwarded-For` arrived from a peer that is not trusted — that
  warning is throttled to once a minute, so look for it rather than expecting
  it to be loud.
* **Cloudflare gives a range up.** You go on trusting it after it is reassigned
  to somebody else, who can then forge `X-Forwarded-For`. This is the direction
  that matters and the only thing that catches it is the date.

## Push notifications

Off by default, because nothing in `docker-compose.yml` provides a push
gateway. Turning it on means running one (sygnal or equivalent, holding your
FCM/APNs credentials) and then telling this server that it, and only it, is an
acceptable destination.

That allowlist is a security control, not a convenience setting.
`POST /_matrix/client/v3/pushers/set` is the one endpoint where an ordinary
user hands the server a URL and the server then makes outbound POSTs carrying
message data to it. With no allowlist that is a self-serve exfiltration feed
and a server-side request forgery primitive in the same request.

So an **empty `allowed_gateway_prefixes` now means no gateway is permitted**,
not "any gateway". If `push.enabled` is true with an empty list the server logs
an error and disables push. It still starts — an upgrade must not brick a
deployment over a key that did not exist in the previous release — but push
will not work until the list is set.

| Setting | Default | What it does |
| --- | --- | --- |
| `enabled` | `false` | Master switch. |
| `allowed_gateway_prefixes` | *(empty — nothing permitted)* | URL prefixes a client may register. Matched on scheme + host + port and then on a path-segment boundary, so `https://push.example.org` does **not** also authorise `https://push.example.org.attacker.tld/`. |
| `allow_internal_gateway` | `false` | Whether a gateway resolving to a private, loopback, link-local or otherwise internal address is allowed at all. |
| `default_payload` | `"event_id_only"` | What goes in the notification. `"full"` sends message bodies to the gateway operator. |

Two things to get right:

**A gateway inside this compose file needs both settings.** The internal-address
check applies *on top of* the allowlist, not only when the allowlist is empty —
so listing `http://sygnal:5000/...` is not sufficient on its own. You also need
`allow_internal_gateway = true`. That check was rewritten after seven ways round
it were found (`0177.0.0.1`, `0x7f.0.0.1`, `127.1`, `localhost.`, IPv4-mapped
IPv6 among them), so do not expect a clever spelling to work as a shortcut —
set the flag.

**`default_payload = "full"` sends message text off your server.** Whoever runs
the gateway sees it, and so does Google or Apple downstream. `event_id_only`
sends an identifier and lets the client fetch the message itself over its own
authenticated connection. Change it only if you run the gateway and have
decided you are comfortable with that.

## Access logs

`nginx/bsfchat.conf.template` defines a `bsfchat` log format and uses it in
every server block. Do not drop it and do not replace it with `combined`.

nginx's built-in `combined` format logs the raw request line including the
query string, and the desktop client fetches media with the session token as a
query parameter — the image and video widgets cannot set an `Authorization`
header. With the default format, `/var/log/nginx/access.log` is a file of
working bearer tokens, readable by anyone in the `adm` group and copied into
every rotated archive. The `map` in the template rewrites the URI **for logging
only**; what nginx proxies upstream is untouched.

It redacts the credential and keeps the rest of the query string, so a
thumbnail request logs as
`/_matrix/media/v3/thumbnail/h/id?width=96&height=96&method=crop&<redacted>`
— the parameters you need to diagnose a media problem survive, the token does
not. It is two `map` blocks rather than one because a single regex can redact
only one occurrence; the second pass drops the whole query string if anything
credential-shaped is still present after the first. `mt=`, the signed media
ticket arriving next release, is already covered. The header comment in the
template says how to add the next parameter and how to check it with `perl`.

Two things this does not do:

- **It is forward-only.** Every access log already written on this host, and
  every rotated archive of one, still contains live tokens — and because token
  expiry slides forward on use, a line from last week can still work today.
  Rotating them is part of deploying this change:

  ```bash
  sudo nginx -t && sudo systemctl reload nginx     # after installing the new conf
  sudo truncate -s 0 /var/log/nginx/access.log
  sudo rm -f /var/log/nginx/access.log.*.gz /var/log/nginx/access.log.?
  sudo truncate -s 0 /var/log/nginx/error.log
  sudo rm -f /var/log/nginx/error.log.*.gz /var/log/nginx/error.log.?
  ```

  If your nginx config predates this template — hand-written under
  `sites-enabled/` rather than rendered by `./setup.sh` — none of the above
  reaches it. Copy the `map`, the `log_format` and the `access_log` lines into
  it by hand, or the logs keep filling with tokens no matter how often you
  rotate them.

  If you have any reason to think a copy of those logs left the host, make
  everyone re-authenticate as well. `./backup.sh` deliberately does not touch
  `/var/log`, so it cannot turn a log-rotation problem into a backup-retention
  problem — but if you have your own backup job that sweeps `/var/log`, its
  archives are in scope here too.

- **The error log cannot be scrubbed, only suppressed.** This is a real
  ceiling, so it is worth being exact about.

  nginx's error log has no `log_format` equivalent. Its entries carry a
  `, request: "GET /uri?... HTTP/1.1"` suffix built from the request line
  exactly as received, and no directive changes it — a rewrite does not reach
  it either. A token in the URL therefore cannot be scrubbed out of the error
  log; it can only be kept out of the URL, or suppressed along with everything
  else at that log level.

  It is smaller than it sounds. At the default `error` level a routine 404 or
  403 is not an error-log event at all. What writes an error-level entry *with*
  the request line, on a request that may carry `?access_token=`, is a 413 past
  `client_max_body_size` and an upstream failure or timeout — and both are
  already rare here because of decisions already in the config: nginx's body
  limit is rendered 8MB above the server's, so oversized uploads are refused by
  the server with a JSON error rather than by nginx with a 413; and
  `proxy_read_timeout` is 330s, above the server's 300s long-poll cap, so a
  normal `/sync` does not become a 504. What is left is genuinely occasional —
  a server restart or crash with media requests in flight logs one line per
  in-flight request.

  **The real fix is the token leaving the URL**, which arrives with signed media
  tickets in the release after this one. Until then the only lever is
  `error_log ... crit;`, which drops everything at `error` level and so costs
  you the diagnostics for exactly the failures you would want to debug. It ships
  commented out in `location /` for that reason. Turn it on only if you have
  decided tokens-on-disk is the bigger risk for your deployment, and verify it
  with the recipe in the file rather than assuming.

  Either way, rotate `/var/log/nginx/error.log*` along with the access log
  above. No config change retracts what is already written.

  `logrotate/nginx` in this repo does exactly that, with a 14-day period, and
  the glob covers `error.log` for this reason rather than incidentally.
  Installing it is in **"Retention and rotation"** below. Until you do, this
  deployment's log retention is whatever the nginx package happened to ship —
  which on Debian and Ubuntu sets `notifempty`, and that quietly does not
  expire a log that is usually empty. The error log on a healthy deployment is
  usually empty.

One related thing not to do: **do not add security headers for media in nginx.**
The chat server sets `X-Content-Type-Options`, `Content-Security-Policy`,
`X-Frame-Options`, `Referrer-Policy` and `Cross-Origin-Resource-Policy` on media
responses itself. An `add_header` inside a `location` replaces the whole
inherited set rather than adding to it, so a well-meaning copy in nginx both
drops headers the application set and emits a duplicate
`X-Content-Type-Options`. Leave those to the app.

## Backup and restore

`./backup.sh` is the supported path. `cp`, `rsync` and `tar` are not.

### Why not `cp`

The databases run in WAL mode, so `data/server/bsfchat.db` is not the whole
database at any given moment — recent transactions are in `bsfchat.db-wal` and
there is no clean checkpoint at shutdown to rely on. A copy of just
`bsfchat.db` silently loses them, and can catch the main file mid-write and
produce something that is not a valid database at all. Copying all three files
is not atomic either: three files from three different instants of a live
database is a different kind of torn.

`./backup.sh` uses SQLite's online backup API (`sqlite3 .backup`), which takes a
consistent point-in-time snapshot of a database that is still serving traffic,
then runs `PRAGMA integrity_check` on the result before calling it a backup.
No downtime, no `docker compose stop`.

### Taking one

```bash
./backup.sh                  # -> ./backups/bsfchat-<UTC timestamp>.tar.gz
./backup.sh /mnt/backups     # somewhere else
./backup.sh --no-media       # skip uploads; much smaller, see below
```

The archive contains the two databases, `data/identity/keys/` (the OIDC signing
key), `.env` (the TURN secret and your host names) and, unless you passed
`--no-media`, `data/server/media/`.

`--no-media` is there because on a busy server the uploads dominate the size.
Understand what you are choosing: the database still references every one of
those files, so a restore without them serves a broken image or a failed
download for every attachment ever posted, forever. Back media up separately if
you skip it here.

The archive is written `0600`, **and it is a complete plaintext copy of the
server.** Every message, the signing key, the TURN secret. The mode stops at
the filesystem it is written to — encrypt it before it goes anywhere else:

```bash
./backup.sh /tmp
age -r <recipient> -o bsfchat-<stamp>.tar.gz.age /tmp/bsfchat-<stamp>.tar.gz
shred -u /tmp/bsfchat-<stamp>.tar.gz
```

This is scheduled by `systemd/bsfchat-backup.timer`, nightly, with a 30-day
retention period enforced by `./backup.sh --prune-older-than`. Nothing is
scheduled until you install it — see **"Retention and rotation"** below for the
runbook.

That section replaces the crontab this one used to suggest. The cron line is
gone rather than kept as an alternative, for three reasons worth knowing if you
are tempted to reinstate it: `find -delete` in a crontab is neither reviewable
nor dry-runnable, a crontab has no equivalent of `Persistent=true` so a host
that was off simply skips the night, and the `>> /var/log/bsfchat-backup.log`
it redirected into was a fourth log file with no rotation of its own.

### Proving it restores

An untested restore path is not a backup. `--verify` unpacks an archive into a
scratch directory and asks SQLite whether what comes out is actually a usable
database:

```bash
./backup.sh --verify backups/bsfchat-20260919T041500Z.tar.gz
```

It reports `integrity_check` on both databases and confirms the signing key,
`.env` and media are present. Run it on a schedule against a real archive — a
backup that has only ever been written is a backup nobody has tested.

### Restoring

This replaces the server's data with the archive's. Read it through before
starting.

```bash
cd /root/bsfchat/deploy

# 0. Prove the archive is good BEFORE you destroy anything.
./backup.sh --verify /path/to/bsfchat-<stamp>.tar.gz

# 1. Stop everything. A restore into a running server is a corrupt server.
docker compose down

# 2. Keep what is there now. This is your undo, and restores go wrong.
mv data data.before-restore-$(date -u +%Y%m%dT%H%M%SZ)

# 3. Unpack.
tar xzf /path/to/bsfchat-<stamp>.tar.gz -C /tmp
mv /tmp/bsfchat-<stamp>/data ./data

# 4. .env. If you are restoring onto the SAME host, keep the .env you have.
#    If this is a new host, or .env is gone, take the one in the archive —
#    TURN_SECRET must match what the restored database's clients expect, and
#    CHAT_HOST is baked into every user ID and cannot be changed.
#    cp /tmp/bsfchat-<stamp>/.env ./.env

# 5. Re-render the configs and fix ownership and modes for this host.
./setup.sh

# 6. Start, and watch the first start: schema migrations run forward here if
#    the archive predates your current image.
docker compose up -d
docker compose logs -f server

# 7. Check it from outside.
curl -s http://127.0.0.1:8448/_matrix/client/versions | jq .
curl -s http://127.0.0.1:8480/.well-known/openid-configuration | jq .

# 8. Only once you have signed in and read a channel:
#    rm -rf data.before-restore-*
```

Three things that bite:

- **The restored database has no `-wal`/`-shm` beside it.** That is correct —
  `sqlite3 .backup` produces a checkpointed file. Do not go looking for them.
- **Schema migrations are forward-only.** Restoring an old archive under a
  newer image migrates it forward on first start and there is no way back, so
  step 2 matters. Restoring a *newer* archive under an older image is refused
  at startup rather than attempted.
- **`CHAT_HOST` is part of every user ID** (`@you:CHAT_HOST`). Restoring onto a
  different domain does not rename anyone; it orphans every account. Restore
  onto the same server name.

## Retention and rotation

Two periods, and both of them are in the privacy policy at
bsfchat.com/privacy:

| What | Period | Enforced by |
| --- | --- | --- |
| nginx access and error logs | **14 days** | `logrotate/nginx` -> `/etc/logrotate.d/nginx` |
| backup archives | **30 days** | `systemd/bsfchat-backup.*` + `./backup.sh --prune-older-than` |

**Everything in this repo is inert until you install it.** The files are
committed and rendered; nothing copies them into `/etc` and nothing enables a
timer, because a unit that writes a complete plaintext copy of the server every
night is not something a config script should switch on behind your back. Until
you work through this section, this deployment keeps logs on whatever schedule
the nginx package set and takes **no backups at all**.

If you change either number, change the policy too. A policy that states a
retention period it does not implement is the specific failure that document
exists to avoid.

### Why log retention is a security control here, not housekeeping

The `bsfchat` log format keeps session tokens out of the access log. Nothing
keeps them out of the **error** log: nginx has no `log_format` for it, its
entries carry the request line as received, and the desktop client fetches
media with the token as a query parameter. Token expiry slides forward on use,
so an error-log line from last week can still be a live credential. Rotation is
the only expiry those tokens have until signed media tickets take the token out
of the URL. See "Access logs" above for the full reasoning.

So the 14 days is a bound on credential exposure. Treat a broken rotation as a
security incident, not a full disk.

### Before you start: size the disk, and rescue old archives

Thirty nightly archives including media is a different footprint from the one
backup a month you have been taking by hand. Measure first:

```bash
cd /root/bsfchat/deploy
df -h .
du -sh data/server/media data/server/bsfchat.db data/identity/identity.db
du -sk data/server/media data/server/bsfchat.db data/identity/identity.db \
  | awk '{t+=$1} END {printf "one archive <= %d MB, 30 of them <= %.1f GB\n", \
                             t/1024, t*30/1048576}'
```

That is an upper bound — the archive is gzipped, though media mostly is not. If
30 of them plus normal headroom does not fit, read "Should the nightly backup
skip media?" below **before** enabling the timer, not after the disk fills.

Then deal with what is already in `backups/`. **The first run will delete every
archive there that is 30 days old or older**, including ones you took by hand
and meant to keep. Look before you enable anything:

```bash
./backup.sh --prune-only --prune-older-than 30 --dry-run backups
```

That is read-only. Anything it lists is going. Move it off the host (encrypted
— see `backup.sh`'s header for the `age` recipe) or accept losing it.

Also confirm the clock, because the timer fires in local time while archive
names are stamped in UTC:

```bash
timedatectl | grep 'Time zone'
```

### Step 1 — purge the nginx logs that are already on disk

Rotation is forward-only. Every access and error log on this host right now,
and every rotated archive of one, keeps whatever it already contains until the
new policy ages it out — which for a `.14.gz` is two weeks of holding live
tokens. Truncate instead of waiting.

```bash
# What you are about to destroy, so it is a decision and not a surprise:
grep -c 'access_token=' /var/log/nginx/access.log /var/log/nginx/error.log
ls -l /var/log/nginx

# truncate, not rm: nginx holds these files open, and deleting the inode
# sends every subsequent log line to a file nobody can read.
truncate -s 0 /var/log/nginx/access.log /var/log/nginx/error.log
rm -f /var/log/nginx/access.log.*.gz /var/log/nginx/access.log.?
rm -f /var/log/nginx/error.log.*.gz  /var/log/nginx/error.log.?

# The new config creates files 0600, but a rename preserves the old mode, so
# the files already here keep 0640 until they are recreated. Fix them now.
chmod 600 /var/log/nginx/*.log
```

Verify:

```bash
ls -l /var/log/nginx                       # only access.log and error.log, 0600, size 0
grep -c 'access_token=' /var/log/nginx/*.log   # want 0
```

If you have any reason to think a copy of those logs left this host, make
everyone re-authenticate as well. Rotating a file does not revoke a token that
has already been read out of it.

There is no undo for this step, which is the point.

### Step 2 — install the logrotate config

First check the assumption the config's `create` line makes. The new log file's
owner **must** be the user nginx's workers run as, or nginx reopens a file it
cannot write and logging stops silently while the service keeps serving:

```bash
nginx -T 2>/dev/null | grep -E '^\s*user\s'    # expect: user www-data;
ps -o user=,comm= -C nginx | sort -u
```

If that is not `www-data`, edit the `create` line in
`/root/bsfchat/deploy/logrotate/nginx` before installing it, and fix
`logrotate/nginx` in the repo so the next deployment does not reinstate it.

Then install it **as** `/etc/logrotate.d/nginx`, replacing the packaged file:

```bash
# Keep the packaged one. This is your undo.
cp -a /etc/logrotate.d/nginx /root/logrotate.d-nginx.packaged.bak
ls -l /root/logrotate.d-nginx.packaged.bak

cp /root/bsfchat/deploy/logrotate/nginx /etc/logrotate.d/nginx

# NOT optional. logrotate SILENTLY IGNORES a config file in logrotate.d that
# is not owned by uid 0 -- it prints "Ignoring nginx because the file owner is
# wrong" and still exits 0. A copy made by anything other than root, or
# unpacked from a tarball, lands with the wrong owner and your retention
# policy simply does not run while everything looks healthy.
chown root:root /etc/logrotate.d/nginx
chmod 644 /etc/logrotate.d/nginx
ls -l /etc/logrotate.d/nginx                   # want: -rw-r--r-- root root
```

**Do not install it under a second name alongside the packaged file.** logrotate
reads `/etc/logrotate.d` in alphabetical order, the second file to claim
`/var/log/nginx/*.log` is skipped with `duplicate log entry`, and the whole
logrotate run then exits 1 — which puts `logrotate.service` into `failed` every
night and buries real failures for every other log on the box. Which retention
period applies would also depend on a filename's sort order.

One thing the packaged file does that this one does not: a `prerotate` hook
running `/etc/logrotate.d/httpd-prerotate`. That directory only exists if some
other package installed it, and nothing in this deployment uses it. If you have
one, add the hook back.

### Step 3 — verify the rotation before trusting it

```bash
# 1. Syntax, and that logrotate is not ignoring the file. Both greps want
#    NO output.
logrotate -d /etc/logrotate.conf 2>&1 | grep -i 'ignoring'
logrotate -d /etc/logrotate.conf 2>&1 | grep -i 'duplicate'
logrotate -d /etc/logrotate.conf 2>&1 | grep -i '^error'

# 2. Confirm nothing else on this host also claims these paths.
grep -rl '/var/log/nginx' /etc/logrotate.d/ /etc/logrotate.conf
#    want exactly: /etc/logrotate.d/nginx

# 3. Confirm the settings logrotate actually parsed. Want "after 1 days" and
#    "(14 rotations)", and — the one that matters — NOT "empty log files are
#    not rotated". The exact phrasing of this line varies by logrotate
#    version: 3.22 spells out "empty log files are rotated, (14 rotations),
#    old logs are removed after 14 days", while 3.21 prints only
#    "after 1 days (14 rotations)" and says nothing about maxage either way.
#    The negative check is the reliable one on both.
logrotate -d /etc/logrotate.conf 2>&1 | grep -A1 'rotating pattern: /var/log/nginx'

# 4. Force one real rotation now.
echo 'runbook test line' >> /var/log/nginx/access.log
logrotate -vf /etc/logrotate.d/nginx

# 5. The part that actually matters: did nginx reopen, and is it still
#    logging? A failed reopen looks exactly like a quiet server.
ls -l /var/log/nginx
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/
tail -3 /var/log/nginx/access.log         # want that curl in the NEW file
systemctl status nginx --no-pager | head -5
```

Step 4 is what closes the loop: if `access.log` is still 0 bytes after that
`curl`, nginx is writing to a deleted inode and you must
`systemctl reload nginx` and work out why the `postrotate` signal did not land.

Confirm something will run this daily. On Debian and Ubuntu that is a systemd
timer, enabled out of the box:

```bash
systemctl is-enabled logrotate.timer          # want: enabled
systemctl list-timers logrotate.timer --no-pager
```

If there is no `logrotate.timer`, `/etc/cron.daily/logrotate` is the fallback;
confirm `cron` is running.

**Undo steps 2 and 3:**

```bash
cp -a /root/logrotate.d-nginx.packaged.bak /etc/logrotate.d/nginx
chown root:root /etc/logrotate.d/nginx
logrotate -d /etc/logrotate.conf 2>&1 | grep -iE 'ignoring|duplicate|^error'
```

### Step 4 — render and install the backup units

```bash
cd /root/bsfchat/deploy
git pull

# Renders systemd/bsfchat-backup.service with THIS deployment's absolute path
# and retention period. It re-renders the other configs too and creates
# backups/ at 0700; it does not restart anything.
./setup.sh

# Read what it produced before installing it. A unit with a wrong absolute
# path fails in the quietest way available: a timer that fires on schedule
# forever and never produces a backup.
grep -E '^(WorkingDirectory|ExecStart)' systemd/bsfchat-backup.service
```

Both `ExecStart` lines must name the real deployment directory and end in
`backups`, and both must carry `--require-private-dest`.

```bash
cp systemd/bsfchat-backup.service systemd/bsfchat-backup.timer /etc/systemd/system/
chown root:root /etc/systemd/system/bsfchat-backup.service \
                /etc/systemd/system/bsfchat-backup.timer
chmod 644 /etc/systemd/system/bsfchat-backup.service \
          /etc/systemd/system/bsfchat-backup.timer
systemctl daemon-reload

systemd-analyze verify /etc/systemd/system/bsfchat-backup.service   # want: silence
systemd-analyze verify /etc/systemd/system/bsfchat-backup.timer     # want: silence
ls -ld backups                                                      # want: drwx------
```

`./setup.sh --check` from now on warns if the installed unit drifts from the
rendered one, the same way it does for the nginx config.

### Step 5 — one run by hand, before the timer

Never let a schedule be the first thing that runs this.

```bash
cd /root/bsfchat/deploy

# Read-only: what retention will delete on the first run.
./backup.sh --prune-only --prune-older-than 30 --dry-run backups

systemctl start bsfchat-backup.service
systemctl status bsfchat-backup.service --no-pager
journalctl -u bsfchat-backup.service --no-pager -n 40
```

In that journal, in this order: the retention lines first, then `space:`, then
the two `snapshot: ... integrity ok` lines, then `Wrote ... mode 0600`. Retention
runs **before** the backup on purpose — see the comment block in the unit.

Then prove the archive is real, which is the only part of a backup that can be
silently wrong:

```bash
ls -l backups
./backup.sh --verify backups/bsfchat-<stamp>.tar.gz
```

If the unit failed, the two likely causes are both loud in the journal:
`backups` is not `0700` (`chmod 0700 backups`), or `sqlite3` is not installed
(`apt-get install -y sqlite3`).

### Step 6 — enable the timer

```bash
systemctl enable --now bsfchat-backup.timer
systemctl list-timers bsfchat-backup.timer --no-pager
```

`NEXT` should be tomorrow at 04:15 and `ACTIVATES` should be
`bsfchat-backup.service`. Enable the **timer**, never the service — the service
is a `oneshot` the timer starts, and `systemctl enable bsfchat-backup.service`
is a no-op that looks like it worked.

Check it again the next morning, and make this the routine:

```bash
systemctl list-timers bsfchat-backup.timer --no-pager   # LAST/PASSED populated
journalctl -u bsfchat-backup.service --since yesterday --no-pager
systemctl --failed                                      # want: 0 loaded units
ls -lt backups | head -5
df -h /root
```

**Undo step 6, and step 4:**

```bash
systemctl disable --now bsfchat-backup.timer
rm -f /etc/systemd/system/bsfchat-backup.timer \
      /etc/systemd/system/bsfchat-backup.service
systemctl daemon-reload
systemctl list-timers --all --no-pager | grep bsfchat    # want: nothing
```

Disabling the timer stops the pruning as well as the backups, so the archives
already on disk then sit there past 30 days with nothing expiring them. If you
turn this off and leave it off, delete them by hand.

### What "30 days" means exactly

`--prune-older-than 30` deletes archives **30 or more days old**, so what
survives is the last 30 days — with one backup a night, 30 archives, none of
them 30 days old. Age comes from the filesystem mtime, not from the stamp in
the filename, so an archive copied or restored into `backups/` counts as new
from the moment it landed. The stamp in the name is the real backup time.

It only ever touches files named `bsfchat-<stamp>.tar.gz` directly in that one
directory. A `bsfchat-<stamp>.tar.gz.age` you encrypted in place does **not**
match — which also means nothing expires it, so it is on you.

For logs: a line is deleted at most 14 days after the rotation that captured
it, so a line written just after one rotation can live a few hours short of 15
days. The period is a 14-day ceiling on rotated data, not a promise about the
file currently being written.

### Should the nightly backup skip media?

**Recommendation: start with full nightly backups, which is the default, and
only move to `--no-media` if the sizing at the top of this section says 30 of
them will not fit comfortably.**

The reasoning, because it cuts both ways. Media is immutable blobs, so 30
nightly archives contain 30 copies of the same bytes and the 30th copy has
exactly the restore value of the first — pure duplication, and it dominates the
archive on any server people actually post to. But a `--no-media` restore
serves a broken image or a failed download for every attachment ever posted,
permanently, because the database still references every one of them. A large
disk is a cheaper problem than a permanently lossy restore, so full-by-default
is the right way round.

If space says otherwise, the shape that keeps both properties is **daily
`--no-media` plus a weekly full**: duplication drops to about four media
copies, and a complete restore is never more than seven days stale. Set it up
with a drop-in rather than by editing the installed unit:

```bash
mkdir -p /etc/systemd/system/bsfchat-backup.service.d
cat > /etc/systemd/system/bsfchat-backup.service.d/no-media.conf <<'EOF'
[Service]
# The empty ExecStart= is required: without it this ADDS a second command
# rather than replacing the inherited one, and you get two backups a night.
ExecStart=
ExecStart=/root/bsfchat/deploy/backup.sh --no-media --require-private-dest /root/bsfchat/deploy/backups
EOF
systemctl daemon-reload
systemctl cat bsfchat-backup.service      # confirm ONE ExecStart, with --no-media
```

Then a weekly full one. Note it keeps `--prune-older-than` out of its own
ExecStartPre: the nightly unit already prunes the shared directory, and the
weekly full archives age out on the same 30-day clock as everything else.

```bash
cat > /etc/systemd/system/bsfchat-backup-full.service <<'EOF'
[Unit]
Description=BSFChat weekly full backup (including media)

[Service]
Type=oneshot
WorkingDirectory=/root/bsfchat/deploy
UMask=0077
Nice=19
IOSchedulingClass=idle
TimeoutStartSec=7200
ExecStart=/root/bsfchat/deploy/backup.sh --require-private-dest /root/bsfchat/deploy/backups
EOF
cat > /etc/systemd/system/bsfchat-backup-full.timer <<'EOF'
[Unit]
Description=Weekly full BSFChat backup

[Timer]
OnCalendar=Sun *-*-* 03:15:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now bsfchat-backup-full.timer
systemctl list-timers 'bsfchat-*' --no-pager
```

Keep the two an hour apart so a long full backup does not overlap the nightly
prune.

The real answer to the duplication is hard-linking unchanged media between
archives instead of copying it, which would make 30 full backups cost about one
plus the deltas. That is a rewrite of how `backup.sh` handles media and it is
not done here.

### What this does NOT fix

Say the quiet part out loud, because automating a backup changes the risk
rather than only reducing it.

- **Thirty plaintext copies of the whole server now live next to the server.**
  Each archive holds every message ever sent, the audit log, every uploaded
  file, the OIDC RSA signing key — which mints tokens for **any** account — and
  `.env`, which holds the TURN shared secret. None of it is encrypted at rest.
  One archive taken by hand and encrypted off the host was a materially smaller
  exposure than thirty sitting in `backups/`.

  What is in place is a bound, not a fix: `0700` on the directory, `0600` on
  every archive, a refusal to run at all if either widens
  (`--require-private-dest`), and a 30-day ceiling. Anyone who gets root on
  this host, or a read of its filesystem, still gets everything.

  The actual fix is to encrypt each archive to a public key whose private half
  is **not on this host**, and ship it off the machine. That can be bolted on
  as an `ExecStartPost` without touching `backup.sh` — the `age` recipe is in
  `backup.sh`'s header. It is not done here because it needs a recipient key
  and a destination, and inventing either without somewhere tested to put them
  would be worse than leaving this written down.

- **Thirty local copies are not off-site.** They survive a bad migration or a
  fat-fingered `rm`. They do not survive the disk, the VPS, or the provider
  account.

- **Nothing verifies the archives on a schedule.** `--verify` proves an archive
  restores, and Step 5 runs it once, by hand. A weekly timer running
  `./backup.sh --verify` against the newest archive would close that; it is not
  set up here.

- **Error-log tokens are bounded, not eliminated.** 14 days is an expiry, not a
  redaction. The fix is the token leaving the URL — signed media tickets — see
  "Access logs".

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
so rolling the image back does not roll the database back. Take a backup
before upgrading anything you cannot afford to lose — `./backup.sh`, not a
`cp` of `data/`, for the reasons in "Backup and restore" above.

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

`./setup.sh` also sets modes, and the two rendered configs that carry the TURN
shared secret — `config/server.toml` and `config/turnserver.conf` — are chowned
to the uid that reads them (10001 for the server, 65534 for coturn, which runs
as `nobody`) and set to `0640`. If it could not chown them it leaves them
`0600` and says so, which is correct under rootless docker and means "not run
as root" on a rootful host. It deliberately does **not** widen them to `0644`
to make a container start: a container that will not start is loud and
fixable, a world-readable secret is neither. If coturn exits complaining it
cannot read `/etc/coturn/turnserver.conf`, that is this, and the fix is the
`sudo chown` line setup.sh prints.

`./setup.sh --check` re-checks those modes and warns if anything has gone
world-readable since.

## Logs

```bash
docker compose logs -f           # all services
docker compose logs -f server    # just the chat server
```

These are the application logs: the chat server's and identity service's own
stdout, captured by Docker. The reverse proxy's access logs are a separate
thing with a separate hazard — see "Access logs" above before you copy them
anywhere, and "Retention and rotation" for how long they are kept and why that
period is a security control rather than a disk-space setting. coturn's log is
a third thing again and is not either of these; see the end of this section.

### What is actually in them

Worth knowing before you paste one into an issue, and before you decide how
long to keep them. Both services log at `info` and **the level is not
configurable** — `init_logger("info")` is a literal in each service's
`main.cpp`, with no config key and no flag. You cannot quiet these lines down;
you can only decide how long they live.

What the lines contain:

- **Account identifiers, constantly.** Every login, registration, password
  change, session revocation and account deactivation is logged with the user
  id. So is every room creation and join, every kick, ban, unban and invite
  (actor *and* target), every voice join and leave, every media upload with its
  uploader, and every content or user report with both the reporter and the
  person reported. Taken together that is a per-account timeline of when
  somebody was online, which channels they were in, who they spoke to in voice
  and who they reported — which is a good deal more revealing than an nginx
  access line, and it is the reason this is a privacy question and not only a
  disk question.
- **Room and channel ids**, alongside those account ids.
- **Usernames.** The identity service logs `Account created: <username> (<id>)`.
- **The OIDC subject** on an identity login, next to the local user id.
- **Nicknames, as free text** — `User X set nickname of Y to '<whatever they
  typed>'` is the one place user-authored content reaches the log. It cannot
  forge log records (`validate_nickname` rejects control, invisible and
  bidi codepoints before it is stored), but it is somebody's chosen text.

What they do **not** contain, each checked rather than assumed:

- **No message content, ever.** Nothing logs an event body. The closest thing
  is a report line, which records the report's id and score but not the
  reported text.
- **No tokens, secrets or password hashes.** Config warnings name keys and
  print `set`/`missing`, never values; the instance secret is logged as having
  been generated, not as a value. The unhandled-exception handler prints the
  matched **route pattern** rather than the raw path where it can, and
  `httplib` keeps the query string out of `req.path` in any case, so the media
  token that rides in a query parameter does not land here the way it can in
  nginx's error log.
- **No full IP addresses.** Every address that reaches these logs goes through
  a redactor first: IPv4 is truncated to a `/24` and IPv6 to a `/64`. That is
  deliberate and it is worth not undoing.

### How long they are kept, and why that is not a number of days

`docker-compose.yml` now sets a `logging:` block on every service. Before it,
Docker's default `json-file` driver kept this output under
`/var/lib/docker/containers/` **with no size limit and no age limit** — it grew
until the disk filled. `logrotate/nginx` never touched it and neither does
`./backup.sh`.

The block caps each service at `max-size` x `max-file` = **30 MB** by default,
which for these lines is roughly 165,000 of them. The arithmetic and the
measured per-line overhead are in the comment above `x-logging:` in
`docker-compose.yml`.

**This is a size bound and not a retention period, and the difference matters
if you publish one.** Docker's `json-file` driver takes `max-size`, `max-file`
and `compress` and nothing else; `max-age` and `max-file-age` are rejected by
the daemon as unknown options. So the oldest line in the ring is however old
the traffic happens to make it: a busy server drops lines inside a week, and a
quiet server — the likely case for a small instance — can hold months. That is
the same shape of trap as `notifempty` in `logrotate/nginx`: the mechanism
keeps the most data on the deployments that look healthiest, because they are
the ones producing the fewest lines.

If you need container logs to expire on a clock the way the nginx logs do, a
size cap will not get you there and neither will a bigger one. The route that
does:

```bash
# 1. Switch the driver in docker-compose.yml — replace the `logging:` line on
#    each service with:
#        logging:
#          driver: journald
#
# 2. Make the journal persistent. Without this it is volatile (RAM only) and
#    every container log is lost on reboot, which is a different retention
#    policy than the one you meant to set.
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create

# 3. Give journald the period, as a DROP-IN rather than an edit to the packaged
#    journald.conf. A drop-in survives a package upgrade, and it cannot fail
#    silently the way `sed -i` over the packaged file does: on a host where the
#    commented `#MaxRetentionSec=` line is missing, that sed matches nothing,
#    changes nothing, and exits 0.
sudo install -d -m 0755 /etc/systemd/journald.conf.d
printf '[Journal]\nMaxRetentionSec=14d\n' \
  | sudo tee /etc/systemd/journald.conf.d/10-bsfchat-retention.conf
sudo systemctl restart systemd-journald

# 4. Prove journald agrees, BEFORE trusting it. This prints the value in
#    effect, not the value in the file you just wrote.
journalctl --header 2>/dev/null | head -3
sudo systemd-analyze cat-config systemd/journald.conf | grep -i maxretention

# 5. Recreate the containers onto the new driver, then prove it reads back.
sudo docker compose up -d
docker inspect -f '{{.Name}} {{json .HostConfig.LogConfig}}' $(docker compose ps -q)
journalctl CONTAINER_NAME=bsfchat-server -n 20
```

`docker compose logs` keeps working on the journald driver. What you give up
is a per-container cap: retention becomes global and shares `SystemMaxUse` with
every other unit on the box, so a noisy neighbour can evict chat-server lines
early and a chat-server flood can evict everything else. That is a real trade,
which is why the shipped default is the size cap — it needs no host state, it
cannot be silently un-done by an unrelated edit to `journald.conf`, and its
failure mode is losing old logs rather than filling a disk.

### Check what your host is actually doing

None of the following can be answered from this repository; run them on the
server.

```bash
# Is there a daemon-wide default that would apply instead? (This file wins for
# containers created before the compose block existed.)
cat /etc/docker/daemon.json 2>/dev/null || echo 'no daemon.json'

# What are the RUNNING containers using? A logging: block only takes effect on
# a container that has been recreated since it was added, so this can disagree
# with docker-compose.yml until you `docker compose up -d`.
docker inspect -f '{{.Name}} {{json .HostConfig.LogConfig}}' $(docker compose ps -q)

# How much is on disk right now, and which container owns it?
sudo du -sh /var/lib/docker/containers/
sudo du -sh /var/lib/docker/containers/*/ | sort -h | tail -5
```

If that last number is already large, the cap does **not** retroactively shrink
it: Docker applies `max-size` as the live file grows past it, so an existing
400 MB log is trimmed only as new lines arrive. Recreating the containers
(`docker compose up -d --force-recreate`) starts fresh files and discards the
old ones, which is the quick way to reclaim the space — at the cost of the
history in them.

### coturn's log is not here

coturn as configured writes **nothing** to stdout, so `docker logs coturn` is
empty and the `logging:` block above never sees anything from it. It opens its
own log file instead and, running as `nobody`, falls back from `/var/log` to
`/var/tmp/turn_<pid>_<date>.log` **inside the container** — invisible to
`docker logs`, unbounded by anything in this repo, and cleared only when the
container is recreated, which under `restart: unless-stopped` may be months.

At the verbosity `config/turnserver.conf.template` uses, that file holds the
startup banner and the server's own listener and relay addresses. It does not
hold client addresses, usernames or per-session lines — those appear only if
you add `verbose`. If you ever do, understand what you have created: an
unbounded record, inside a container, of which addresses called which, that
nothing in this repo rotates and no backup captures.

```bash
docker compose exec coturn sh -c 'ls -la /var/tmp/turn_*.log'
```
