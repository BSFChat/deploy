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

# Everything this script creates is either a secret or config for a secret:
# .env, the rendered server.toml and turnserver.conf all carry the TURN shared
# secret, and the data directories hold the message database. Default to
# owner-only and widen deliberately below, rather than creating files at
# whatever umask the operator's shell happens to have and hoping.
#
# This also closes a narrower hole: the .env.tmp written during TURN_SECRET
# generation was created at the ambient umask and only chmod'ed after the
# rename, so the freshly generated secret was briefly world-readable.
umask 077

cd "$(dirname "$0")"

# uids the container images run as. The rendered configs are bind-mounted into
# containers that are NOT root, so a root-owned 0640 file is a file the
# container cannot read — which presents as the service exiting at startup with
# a message that reads like an application bug. Keep these in sync with
# server/Dockerfile (USER 10001:10001) and with the coturn image, which runs as
# nobody:nogroup.
SERVER_UID=10001
COTURN_UID=${COTURN_UID:-65534}

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

die() { printf '\n  ERROR: %s\n\n' "$1" >&2; exit 1; }

# Warn when the nginx config installed on this box is not the one this repo
# renders.
#
# This exists because of a real outage. Production ran for months with
# `proxy_read_timeout 60s` hand-edited into /etc/nginx/sites-enabled/bsfchat,
# while nginx/bsfchat.conf.template here said 330s the whole time. Nothing
# noticed: nginx does not care where its config came from, and the rendered
# file sitting in this directory is not the file nginx reads. A bot parking a
# /sync long poll at the protocol maximum was cut off every 60 seconds and
# went silent for fifteen minutes while reporting itself healthy. See
# "Long polls, proxy timeouts, and the ceiling you cannot raise" in README.md.
#
# A warning, never a failure: a deployment may legitimately have local edits
# (a second server_name, an extra location), and refusing to run over a diff
# would just teach people to skip this script. The point is that the drift is
# SAID OUT LOUD once per run instead of discovered during an incident.
check_installed_nginx() {
    installed=""
    for candidate in /etc/nginx/sites-enabled/bsfchat \
                     /etc/nginx/sites-available/bsfchat \
                     /etc/nginx/conf.d/bsfchat.conf; do
        [ -e "$candidate" ] && { installed=$candidate; break; }
    done
    [ -n "$installed" ] || return 0
    [ -r "$installed" ] || return 0          # not root; say nothing rather than guess
    cmp -s "$installed" nginx/bsfchat.conf && return 0

    note "WARNING: $installed differs from nginx/bsfchat.conf."
    note "         The installed file is what nginx actually serves; this one is"
    note "         only what the templates render. See it with:"
    note "             diff -u $installed nginx/bsfchat.conf"
    note "         If the box is right, fix nginx/bsfchat.conf.template so the"
    note "         next run does not reinstate the difference. If this file is"
    note "         right, install it and reload:"
    note "             cp nginx/bsfchat.conf $installed && nginx -t && systemctl reload nginx"
}
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
# TURN_REALM was not checked here, so a .env that left it at the placeholder
# rendered "successfully" and only failed later in --check, which most people
# never run. Same class of mistake as the three above; same treatment.
case "$TURN_REALM" in
    *example.com|*yourdomain.com)
        die "TURN_REALM is still the placeholder ($TURN_REALM). It must match the
         realm the chat server uses, which is CHAT_HOST. Set it in .env." ;;
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

    # The TURN secret is no longer on coturn's command line, so docker-compose
    # is no longer the thing that notices it is missing. Check it here instead:
    # an empty static-auth-secret starts a relay that rejects every credential
    # the chat server issues, and relayed calls then fail with nothing in any
    # log that points at the cause.
    grep -q '^static-auth-secret=.\+' config/turnserver.conf ||
        die "config/turnserver.conf has no static-auth-secret. Re-run ./setup.sh."
    if ! grep -qF "static-auth-secret=$TURN_SECRET" config/turnserver.conf; then
        die "config/turnserver.conf's static-auth-secret does not match TURN_SECRET in .env.
         coturn would reject every credential the chat server issues and all
         relayed calls would fail. Run ./setup.sh."
    fi

    # Anything world-readable here is a secret handed to every local user:
    # .env, server.toml and turnserver.conf all carry the TURN shared secret.
    # Only the "other" triplet is checked — group read is deliberate on the two
    # files a non-root container has to read.
    for f in .env config/server.toml config/turnserver.conf; do
        mode=$(ls -l "$f" | cut -c1-10)
        case "$mode" in
            *---) ;;
            *) note "WARNING: $f is $mode — every local user can read the TURN"
               note "         shared secret. Anyone holding it can mint valid TURN"
               note "         credentials and relay traffic through this machine."
               note "         Fix with: chmod o= $f  (or re-run ./setup.sh)" ;;
        esac
    done

    check_installed_nginx

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

# Rendering the file is not installing it. Say so if the two have parted.
check_installed_nginx

# ---------------------------------------------------------------------------
# Modes and ownership on the rendered config
# ---------------------------------------------------------------------------
# config/server.toml and config/turnserver.conf both carry the TURN shared
# secret in cleartext. Anyone holding it can mint unlimited valid TURN
# credentials and relay their own traffic through this machine's IP address.
#
# 0640 rather than 0600 because these are bind-mounted into containers that do
# not run as root, so the container's uid needs to be able to read them. Own
# them by that uid and keep the group read bit; "other" gets nothing.
#
# Non-fatal, matching the data-directory chown below: on rootless docker or a
# userns-remap host the mapping is different and chown correctly refuses.
harden_config() {
    file="$1"; owner="$2"
    if chown "$owner" "$file" 2>/dev/null; then
        chmod 640 "$file"
    else
        # Fail CLOSED. The alternative — widening to 0644 so the container can
        # read it whatever uid it runs as — hands the TURN secret to every
        # local user to avoid a startup error, which is the wrong way round: a
        # container that will not start is loud and fixable, a quietly
        # world-readable secret is neither.
        #
        # This branch is normal under rootless docker, where the container's
        # root maps to the invoking user and 0600 is already correct. On a
        # rootful host it means setup.sh was not run as root.
        chmod 600 "$file"
        note "NOTE: could not chown $file to uid $owner; left it 0600 (owner only)."
        note "      Correct for rootless docker. On a rootful host, if the"
        note "      container exits saying it cannot read its config, run:"
        note "        sudo chown $owner $file && sudo chmod 640 $file"
    fi
}

harden_config config/server.toml     "$SERVER_UID"
harden_config config/turnserver.conf "$COTURN_UID"

# These two carry no secret — identity.toml names the deployment's hosts and a
# key *path*, the nginx config names routes — so they stay 0644 and skip the
# chown dance above. umask 077 would otherwise have made them 0600, which the
# identity container (uid 10001) and nginx cannot read.
chmod 644 config/identity.toml nginx/bsfchat.conf

for f in config/server.toml config/identity.toml config/turnserver.conf nginx/bsfchat.conf; do
    if grep -q '\${' "$f"; then
        die "$f still has unsubstituted \${...} placeholders — a template gained a
         variable that setup.sh does not know about. Add it to render()."
    fi
done

mkdir -p data/server data/identity

# The server and identity images run as uid/gid 10001, not root. A bind
# mount keeps the HOST directory's ownership — it does not inherit the
# ownership baked into the image — so without this the containers cannot
# write their database, media or signing keys and fail at startup with a
# permission error that reads like a bug in the application.
#
# Non-fatal: on a rootless-docker or userns-remap host the mapping is
# different and chown will (correctly) refuse.
if chown -R "$SERVER_UID:$SERVER_UID" data/server data/identity 2>/dev/null; then
    note "data/server and data/identity are owned by uid $SERVER_UID (the container user)."
else
    note "WARNING: could not chown data/server and data/identity to $SERVER_UID:$SERVER_UID."
    note "         The containers run as uid $SERVER_UID and need to write there."
    note "         Run:  sudo chown -R $SERVER_UID:$SERVER_UID data/server data/identity"
    note "         (Ignore this if you run rootless docker or userns-remap.)"
fi

# These directories hold, in cleartext: every message ever sent, a second copy
# of every message body in the search index, queued push payloads, the audit
# log, uploaded media, and the identity service's OIDC RSA signing key. None of
# it is encrypted at rest.
#
# Nothing used to set a mode on any of it. mkdir left the directories at the
# ambient umask (0755) and the server created bsfchat.db at 0644, so on a host
# where the deployment does not happen to sit under a 0700 /root, every local
# user could read every conversation on the server. Close that here rather than
# relying on where the operator chose to untar this directory.
#
# 0750, not 0700: the directories are owned by the container uid, so root can
# still get in for backups but nothing else can.
chmod 750 data data/server data/identity 2>/dev/null || true
# The OIDC key directory gets nothing at all for group or other.
[ -d data/identity/keys ] && chmod 700 data/identity/keys 2>/dev/null || true

# Current server images chmod their own database (and its -wal/-shm siblings)
# to owner-only at every start. Do it here too, for the case that matters most:
# an existing deployment that ran an older image for months and whose files are
# already 0644 on disk. find, not a glob, because -wal and -shm come and go.
find data/server -name 'bsfchat.db*' -type f -exec chmod 600 {} + 2>/dev/null || true
find data/identity -name '*.db*' -type f -exec chmod 600 {} + 2>/dev/null || true
# The OIDC signing key. Losing it logs everyone out; leaking it lets the holder
# mint tokens for any account on this server.
find data/identity -name '*.pem' -type f -exec chmod 600 {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# Release channel
# ---------------------------------------------------------------------------
# Say plainly which channel this deployment is on. BSFCHAT_TAG is a single
# line in .env that decides whether you run reviewed releases or tip of
# branch, and it is the setting most likely to be wrong without anyone
# noticing until something breaks.
case "$BSFCHAT_TAG" in
    latest)
        CHANNEL_NOTE="stable — the highest released version" ;;
    latest-beta)
        CHANNEL_NOTE="beta — stable plus release candidates" ;;
    main)
        CHANNEL_NOTE="DEVELOPMENT — tip of branch, unreviewed and untagged" ;;
    v*)
        CHANNEL_NOTE="pinned to this exact release; it will never move" ;;
    *)
        CHANNEL_NOTE="unrecognised. Expected latest, latest-beta, main or vX.Y.Z" ;;
esac

cat <<EOF

  Done.

  Release channel: ${BSFCHAT_TAG}
    ${CHANNEL_NOTE}
    Change it with BSFCHAT_TAG in .env, then:
      ./setup.sh && docker compose pull && docker compose up -d

  Next:
    1. Firewall — open ${TURN_PORT}/tcp, ${TURN_PORT}/udp and
       ${TURN_MIN_PORT}-${TURN_MAX_PORT}/udp (${RELAY_PORTS} relay ports).
    2. DNS — point ${CHAT_HOST}, ${ID_HOST} and ${TURN_HOST}
       at this machine (${TURN_EXTERNAL_IP}).
    3. Reverse proxy — install nginx/bsfchat.conf, then read the TLS note at
       the top of it. Do not leave the origin on plaintext HTTP.
       Install it; do not hand-edit the copy under /etc/nginx. A 60s
       proxy_read_timeout edited in on the box, and never reflected here,
       is what silently blinded an integration bot on /sync. Verify with:
           sudo nginx -t && sudo systemctl reload nginx
           sudo nginx -T | grep -E 'proxy_(read|send)_timeout'
       If you put Cloudflare in front, read "Long polls, proxy timeouts,
       and the ceiling you cannot raise" in README.md first: its ~100s
       origin-pull limit caps /sync below the protocol's 300s maximum and
       no nginx setting raises it.
    4. docker compose up -d

EOF
