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

All services bind to `127.0.0.1` only — use a reverse proxy for public access.

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

## Voice Chat (Optional)

For voice chat to work across NATs, you need a TURN server. Uncomment the `coturn` service in `docker-compose.yml` and:

1. Create `config/turnserver.conf` with your config
2. Update `config/server.toml` to point at it
3. Open UDP port 3478 and the relay port range (e.g. 49152-65535) on your firewall

For LAN-only deployments, set `allow_peer_to_peer = true` in `server.toml` — no TURN needed.

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
