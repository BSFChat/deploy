# BSFChat Deployment

Production docker-compose setup for deploying BSFChat to your own server.

## Quick Start

1. Copy this `deploy/` directory to your server:
   ```bash
   scp -r deploy/ user@your-server:/opt/bsfchat/
   ```

2. On the server, create your `.env` file:
   ```bash
   cd /opt/bsfchat
   cp .env.example .env
   # Edit .env to set MINIO_ROOT_PASSWORD and your domains
   ```

3. Edit the config files:
   - `config/server.toml` — set `name`, `access_key`, `secret_key` (match Minio), and `provider_url`
   - `config/identity.toml` — set `name` and `issuer_url`

4. Start the services:
   ```bash
   docker compose up -d
   ```

## What's Running

- **bsfchat-server** (`localhost:8448`) — the chat server
- **bsfchat-identity** (`localhost:8480`) — OIDC identity provider with web UI
- **bsfchat-minio** (`localhost:9000`) — S3-compatible object storage for media
  - Web console at `localhost:9001`
- **bsfchat-coturn** (host network, port `3478`) — STUN/TURN relay for voice

All HTTP services bind to `127.0.0.1` only — use a reverse proxy for public
access. coturn is the exception: it must be reachable directly (see Voice Chat
below), never proxied.

## Reverse Proxy Setup

Point your proxy at the backend services. Example with Caddy:

```
chat.yourdomain.com {
    reverse_proxy localhost:8448
}

id.yourdomain.com {
    reverse_proxy localhost:8480
}
```

Example with nginx:

```nginx
server {
    server_name chat.yourdomain.com;
    listen 443 ssl http2;
    # ... SSL config ...
    location / {
        proxy_pass http://127.0.0.1:8448;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;  # for /sync long-polling
    }
}

server {
    server_name id.yourdomain.com;
    listen 443 ssl http2;
    # ... SSL config ...
    location / {
        proxy_pass http://127.0.0.1:8480;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## Voice Chat

Voice needs a STUN/TURN server for NAT traversal — without TURN, users behind
symmetric NAT or CGNAT can't connect at all. The compose file runs `coturn`
for this (host networking, so no reverse proxy involved — TURN is not HTTP).

1. Generate a secret: `openssl rand -hex 32`
2. Set it in **both** places (they must match):
   - `config/turnserver.conf` — `static-auth-secret`
   - `config/server.toml` — `turn_secret` under `[voice]`
3. In `config/turnserver.conf`, set `realm` to your domain, and set
   `external-ip` if the server is behind NAT (typical cloud VPS)
4. In `config/server.toml`, point `stun_uri`/`turn_uri` at your domain
5. Open on your firewall:
   - `3478` tcp + udp (STUN/TURN)
   - `49160-49200` udp (media relay range)

The server issues short-lived TURN credentials from the shared secret
(`turn_ttl`, default 3600s) — no static TURN username/password to manage.

## Data Persistence

All data is stored in `./data/`:
- `data/server/` — chat database and (local) media
- `data/identity/` — accounts database and RSA keys
- `data/minio/` — S3 object storage

Back this up regularly.

## Updating

```bash
docker compose pull
docker compose up -d
```

## Logs

```bash
docker compose logs -f           # all services
docker compose logs -f server    # just the chat server
```
