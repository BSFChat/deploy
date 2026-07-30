#!/bin/sh
# Render the BSFChat deployment config from .env.
#
#   ./setup.sh          render config/*.toml and nginx/bsfchat.conf
#   ./setup.sh --check  validate .env and the rendered files, change nothing
#
# Everything under config/ and nginx/ is generated. The tracked sources are
# the *.template files next to them; .env is the only thing you edit.
#
# POSIX sh on purpose — this runs on whatever minimal VPS image you landed
# on, with no bash/gettext/python assumed.

set -eu

cd "$(dirname "$0")"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

die() { printf '\n  ERROR: %s\n\n' "$1" >&2; exit 1; }
note() { printf '  %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
if [ ! -f .env ]; then
    [ "$CHECK_ONLY" = 1 ] && die ".env does not exist. Run: cp .env.example .env"
    note "No .env found — creating one from .env.example."
    cp .env.example .env
    chmod 600 .env
    die ".env created. Edit it (at minimum CHAT_HOST, ID_HOST, TURN_HOST and
         TURN_EXTERNAL_IP), then run ./setup.sh again."
fi

# shellcheck disable=SC1091
. ./.env

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
for var in CHAT_HOST ID_HOST TURN_HOST TURN_REALM TURN_PORT \
           TURN_MIN_PORT TURN_MAX_PORT MAX_UPLOAD_MB \
           REGISTRATION_ENABLED ALLOW_PEER_TO_PEER BSFCHAT_TAG COTURN_TAG; do
    eval "val=\${$var:-}"
    [ -n "$val" ] || die "$var is empty in .env"
done

case "$CHAT_HOST" in
    *example.com|*yourdomain.com|localhost)
        die "CHAT_HOST is still the placeholder ($CHAT_HOST). Set your real domain in .env." ;;
esac
case "$ID_HOST" in
    *example.com|*yourdomain.com)
        die "ID_HOST is still the placeholder ($ID_HOST). Set your real domain in .env." ;;
esac
case "$TURN_HOST" in
    *example.com|*yourdomain.com)
        die "TURN_HOST is still the placeholder ($TURN_HOST). Set your real domain in .env." ;;
esac

# TURN_EXTERNAL_IP: the single most commonly skipped setting, and skipping it
# breaks every relayed call with no error anywhere. Refuse to render without it.
if [ -z "${TURN_EXTERNAL_IP:-}" ]; then
    die "TURN_EXTERNAL_IP is not set in .env.

         coturn advertises the address it sees on its own interface. On a NATed
         VPS that is a private address, so relayed calls fail silently — the
         allocation succeeds and the media goes nowhere.

         Find your public address:   curl -4 https://ifconfig.me
         then set TURN_EXTERNAL_IP in .env and re-run ./setup.sh."
fi
case "$TURN_EXTERNAL_IP" in
    10.*|127.*|192.168.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
        note "WARNING: TURN_EXTERNAL_IP=$TURN_EXTERNAL_IP is a private address."
        note "         Unless this is a LAN-only deployment, relayed calls will"
        note "         not work from the internet. Use your public IP." ;;
esac

# TURN secret: generate rather than ship a placeholder that "works" locally
# (matching CHANGE_ME on both sides) and fails only across real NAT.
if [ -z "${TURN_SECRET:-}" ] || [ "$TURN_SECRET" = "CHANGE_ME_TURN_SECRET" ]; then
    [ "$CHECK_ONLY" = 1 ] && die "TURN_SECRET is unset in .env. Run ./setup.sh to generate one."
    command -v openssl >/dev/null 2>&1 || die "TURN_SECRET is unset and openssl is not installed.
         Set TURN_SECRET in .env to 64 random hex characters."
    TURN_SECRET="$(openssl rand -hex 32)"
    # Replace in place, whether the key is present-but-empty or absent.
    if grep -q '^TURN_SECRET=' .env; then
        sed "s|^TURN_SECRET=.*|TURN_SECRET=$TURN_SECRET|" .env > .env.tmp && mv .env.tmp .env
    else
        printf 'TURN_SECRET=%s\n' "$TURN_SECRET" >> .env
    fi
    chmod 600 .env
    note "Generated a new TURN_SECRET and wrote it to .env."
fi

if [ "$TURN_MIN_PORT" -ge "$TURN_MAX_PORT" ]; then
    die "TURN_MIN_PORT ($TURN_MIN_PORT) must be below TURN_MAX_PORT ($TURN_MAX_PORT)"
fi
RELAY_PORTS=$(( TURN_MAX_PORT - TURN_MIN_PORT + 1 ))
if [ "$RELAY_PORTS" -lt 500 ]; then
    note "WARNING: only $RELAY_PORTS relay ports configured."
    note "         A call of N people needs N*(N-1)*2 of them; a 5-way call"
    note "         alone burns 40. Widen TURN_MIN_PORT/TURN_MAX_PORT."
fi

# nginx gets a little headroom over the server's own limit so that an
# oversized upload is rejected by the server (proper JSON error) rather than
# by nginx (bare HTML 413 the client cannot interpret).
NGINX_MAX_BODY_MB=$(( MAX_UPLOAD_MB + 8 ))

if [ "$CHECK_ONLY" = 1 ]; then
    for f in config/server.toml config/identity.toml \
             config/turnserver.conf nginx/bsfchat.conf; do
        [ -f "$f" ] || die "$f has not been generated. Run ./setup.sh."
        if grep -q 'CHANGE_ME\|yourdomain\.com\|example\.com\|\${' "$f"; then
            die "$f still contains placeholder values. Run ./setup.sh."
        fi
    done
    note "OK: .env is complete and all config files are rendered."
    exit 0
fi

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
# Only ${NAME} is substituted. nginx's own $host / $remote_addr variables have
# no braces and are left untouched.
render() {
    src="$1"; dst="$2"
    sed \
        -e "s|\${CHAT_HOST}|$CHAT_HOST|g" \
        -e "s|\${ID_HOST}|$ID_HOST|g" \
        -e "s|\${TURN_HOST}|$TURN_HOST|g" \
        -e "s|\${TURN_REALM}|$TURN_REALM|g" \
        -e "s|\${TURN_PORT}|$TURN_PORT|g" \
        -e "s|\${TURN_MIN_PORT}|$TURN_MIN_PORT|g" \
        -e "s|\${TURN_MAX_PORT}|$TURN_MAX_PORT|g" \
        -e "s|\${TURN_SECRET}|$TURN_SECRET|g" \
        -e "s|\${MAX_UPLOAD_MB}|$MAX_UPLOAD_MB|g" \
        -e "s|\${NGINX_MAX_BODY_MB}|$NGINX_MAX_BODY_MB|g" \
        -e "s|\${REGISTRATION_ENABLED}|$REGISTRATION_ENABLED|g" \
        -e "s|\${ALLOW_PEER_TO_PEER}|$ALLOW_PEER_TO_PEER|g" \
        "$src" > "$dst"
    note "wrote $dst"
}

render config/server.toml.template     config/server.toml
render config/identity.toml.template   config/identity.toml
render config/turnserver.conf.template config/turnserver.conf
render nginx/bsfchat.conf.template     nginx/bsfchat.conf

# server.toml carries the TURN secret.
chmod 640 config/server.toml

for f in config/server.toml config/identity.toml config/turnserver.conf nginx/bsfchat.conf; do
    if grep -q '\${' "$f"; then
        die "$f still has unsubstituted \${...} placeholders — a template gained a
         variable that setup.sh does not know about. Add it to render()."
    fi
done

mkdir -p data/server data/identity

cat <<EOF

  Done.

  Next:
    1. Firewall — open ${TURN_PORT}/tcp, ${TURN_PORT}/udp and
       ${TURN_MIN_PORT}-${TURN_MAX_PORT}/udp (${RELAY_PORTS} relay ports).
    2. DNS — point ${CHAT_HOST}, ${ID_HOST} and ${TURN_HOST}
       at this machine (${TURN_EXTERNAL_IP}).
    3. Reverse proxy — install nginx/bsfchat.conf, then read the TLS note at
       the top of it. Do not leave the origin on plaintext HTTP.
    4. docker compose up -d

EOF
