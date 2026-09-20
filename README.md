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

A nightly cron, with somewhere to put it that is not this machine:

```cron
15 4 * * *  cd /root/bsfchat/deploy && ./backup.sh >> /var/log/bsfchat-backup.log 2>&1
30 4 * * *  find /root/bsfchat/deploy/backups -name 'bsfchat-*.tar.gz' -mtime +14 -delete
```

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

These are the application logs. The reverse proxy's access logs are a separate
thing with a separate hazard — see "Access logs" above before you copy them
anywhere.
