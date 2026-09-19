#!/bin/sh
# Consistent, offline-safe backup of a running BSFChat deployment.
#
#   ./backup.sh                 write a new archive into ./backups
#   ./backup.sh /mnt/backups    write it somewhere else
#   ./backup.sh --verify FILE   prove that archive actually restores
#   ./backup.sh --no-media      skip uploaded media (much smaller, lossy)
#
# POSIX sh, same as setup.sh: this runs on whatever minimal VPS image you
# landed on.
#
# ---------------------------------------------------------------------------
# Why this script exists, and why `cp` is not a backup here
# ---------------------------------------------------------------------------
# The databases run in WAL mode. That means `data/server/bsfchat.db` is NOT the
# whole database at any given moment: recent transactions live in the sibling
# `bsfchat.db-wal` and have not been folded back into the main file yet, and
# there is no clean checkpoint at shutdown to rely on. So:
#
#   * `cp bsfchat.db` (or a tar that happens to match that glob) silently drops
#     every transaction still in the WAL — and, worse, can catch the main file
#     mid-write and produce a file that is not a valid database at all;
#   * `cp` of all three files is not atomic either. The three copies come from
#     three different instants of a live, concurrently-written database, which
#     is a different kind of torn.
#
# `sqlite3 .backup` uses SQLite's own online backup API: it takes a read lock,
# copies pages, and restarts if a writer moves under it, so the output is a
# single consistent point in time from a database that is still serving traffic.
# That is the only reason this is a script rather than a line in the README.
#
# ---------------------------------------------------------------------------
# What is in the archive, and what that means for where you put it
# ---------------------------------------------------------------------------
# EVERYTHING, IN PLAINTEXT. Nothing in this deployment is encrypted at rest.
# The archive contains every message ever sent on this server, a second copy of
# every message body in the search index, the audit log, queued push payloads,
# every uploaded file, the OIDC RSA signing key (which mints tokens for any
# account), and .env (which holds the TURN shared secret).
#
# The archive is written 0600, but the mode stops at the filesystem it is
# written to. Treat the destination as equivalent to root on this host:
# encrypt it in transit and at rest, and do not push it to object storage,
# a syncing folder or a laptop without encrypting it first, e.g.
#
#   ./backup.sh /tmp && age -r <recipient> -o bsfchat-<stamp>.tar.gz.age \
#       /tmp/bsfchat-<stamp>.tar.gz && shred -u /tmp/bsfchat-<stamp>.tar.gz
#
# Deliberately NOT included: /var/log/nginx. Those logs are not needed to
# restore the service, and they contain session tokens lifted from media URLs —
# tokens whose expiry slides forward on use, so old lines can still be live.
#
# The access log stops collecting them once the `bsfchat` log format in
# nginx/bsfchat.conf.template is deployed. The ERROR log does not: nginx has no
# format control there and a token in the URL cannot be scrubbed out of it,
# only suppressed, until signed media tickets take the token out of the URL
# altogether. So this exclusion is not a transitional measure that expires with
# the next nginx reload — keep it.
#
# Sweeping either log into a retained archive would turn a log-rotation problem
# into a backup-retention problem. If you have a separate job that backs up
# /var/log, rotate the nginx logs first; see "Access logs" in README.md.
#
# Also note: an archive taken before the RC's one-time VACUUM still contains
# deleted-but-not-overwritten data — pre-hash plaintext access tokens dropped
# by schema migration v7, pre-redaction message bodies, and the call-signalling
# rows that migration v17 deleted precisely because they carry participants' IP
# addresses. Rotating those old archives out is part of that fix, not optional.

set -eu

# Everything this script writes is a full copy of the server's secrets.
umask 077

cd "$(dirname "$0")"

die() { printf '\n  ERROR: %s\n\n' "$1" >&2; exit 1; }
note() { printf '  %s\n' "$1"; }

command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is not installed, and a copy taken without it
         is not a consistent backup of a WAL database. Install it:
           Debian/Ubuntu:  sudo apt-get install -y sqlite3
           Alpine:         sudo apk add sqlite
           RHEL/Fedora:    sudo dnf install -y sqlite"

# ---------------------------------------------------------------------------
# --verify: rehearse the restore
# ---------------------------------------------------------------------------
# An untested restore path is not a backup. This unpacks the archive into a
# scratch directory and asks SQLite whether what comes out is a usable
# database, which is the only part of the restore that can silently be wrong.
# Run it against a real archive on a schedule, not once at setup time.
if [ "${1:-}" = "--verify" ]; then
    archive="${2:-}"
    [ -n "$archive" ] || die "Usage: ./backup.sh --verify <archive.tar.gz>"
    [ -f "$archive" ] || die "$archive does not exist."

    scratch=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$scratch'" EXIT INT TERM

    tar xzf "$archive" -C "$scratch" || die "$archive is not a readable tar.gz."

    root=$(find "$scratch" -maxdepth 1 -mindepth 1 -type d | head -n 1)
    [ -n "$root" ] || die "$archive does not contain the expected directory."

    rc=0
    for db in server/bsfchat.db identity/identity.db; do
        path="$root/data/$db"
        if [ ! -f "$path" ]; then
            note "MISSING: data/$db"
            rc=1
            continue
        fi
        result=$(sqlite3 "$path" 'PRAGMA integrity_check;' 2>&1) || result="unreadable: $result"
        if [ "$result" = "ok" ]; then
            users=$(sqlite3 "$path" \
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo '?')
            note "OK: data/$db — integrity_check passed, $users tables"
        else
            note "FAILED: data/$db — $result"
            rc=1
        fi
    done

    for f in data/identity/keys/private.pem .env; do
        [ -f "$root/$f" ] && note "present: $f" || { note "MISSING: $f"; rc=1; }
    done

    if [ -d "$root/data/server/media" ]; then
        note "present: data/server/media ($(find "$root/data/server/media" -type f | wc -l | tr -d ' ') files)"
    else
        note "no media in this archive (taken with --no-media, or none uploaded)"
    fi

    [ "$rc" = 0 ] || die "This archive would NOT restore cleanly. See above."
    note ""
    note "This archive restores. See 'Backup and restore' in README.md for the steps."
    exit 0
fi

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
WITH_MEDIA=1
DEST=backups
for arg in "$@"; do
    case "$arg" in
        --no-media) WITH_MEDIA=0 ;;
        --*) die "Unknown option: $arg" ;;
        *) DEST="$arg" ;;
    esac
done

[ -f data/server/bsfchat.db ] || die "data/server/bsfchat.db does not exist. Is this the right
         directory, and has the server ever started?"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
NAME="bsfchat-$STAMP"
STAGE="$DEST/.$NAME.partial"
ARCHIVE="$DEST/$NAME.tar.gz"

mkdir -p "$DEST" "$STAGE/data/server" "$STAGE/data/identity"
# shellcheck disable=SC2064
trap "rm -rf '$STAGE'" EXIT INT TERM

# ---------------------------------------------------------------------------
# Databases — online, consistent, WAL and all
# ---------------------------------------------------------------------------
# .timeout before .backup: the backup API restarts whenever a writer commits
# under it, and without a busy timeout a moderately active server can make it
# give up immediately. 30s is generous for a database this size.
snapshot() {
    src="$1"; dst="$2"
    [ -f "$src" ] || { note "skipped $src (does not exist)"; return 0; }
    sqlite3 "$src" ".timeout 30000" ".backup '$dst'" ||
        die "sqlite3 .backup failed for $src. Nothing was written."
    # The copy is a plain, checkpointed file with no WAL beside it. Confirm it
    # is a database and not, say, 40MB of zeroes, before calling this a backup.
    check=$(sqlite3 "$dst" 'PRAGMA integrity_check;' 2>&1) || check="unreadable: $check"
    [ "$check" = "ok" ] || die "the snapshot of $src failed integrity_check: $check"
    chmod 600 "$dst"
    note "snapshot: $src -> $(basename "$dst") ($(wc -c < "$dst" | tr -d ' ') bytes, integrity ok)"
}

snapshot data/server/bsfchat.db    "$STAGE/data/server/bsfchat.db"
snapshot data/identity/identity.db "$STAGE/data/identity/identity.db"

# ---------------------------------------------------------------------------
# Everything else the deployment cannot be rebuilt without
# ---------------------------------------------------------------------------
# The OIDC signing key. Not derivable from anything else: lose it and every
# issued token is invalid and everybody is logged out, permanently.
if [ -d data/identity/keys ]; then
    cp -a data/identity/keys "$STAGE/data/identity/keys"
    note "copied: data/identity/keys"
fi

# .env, because it holds TURN_SECRET and the host names. Without it the configs
# cannot be re-rendered and coturn comes back with a different secret, which
# breaks every relayed call on the restored server.
[ -f .env ] && cp -a .env "$STAGE/.env" && note "copied: .env"

# Media is a plain directory of blobs — no consistency problem, just size. It
# is skippable because on a large server it dominates the archive, but a
# restore without it serves broken images and failed downloads forever: the
# database still references every one of them.
if [ "$WITH_MEDIA" = 1 ] && [ -d data/server/media ]; then
    cp -a data/server/media "$STAGE/data/server/media"
    note "copied: data/server/media ($(du -sh data/server/media | cut -f1 | tr -d ' '))"
elif [ "$WITH_MEDIA" = 0 ]; then
    note "SKIPPED media (--no-media). The restored server will 404 every upload."
fi

printf '%s\n' "$STAMP" > "$STAGE/BACKUP_TIMESTAMP_UTC"

# ---------------------------------------------------------------------------
# Seal it
# ---------------------------------------------------------------------------
# Rename the staging directory to its final name first, so the archive's
# top-level directory is stable and --verify/restore can find it.
mv "$STAGE" "$DEST/$NAME"
# shellcheck disable=SC2064
trap "rm -rf '$DEST/$NAME'" EXIT INT TERM

tar czf "$ARCHIVE" -C "$DEST" "$NAME"
chmod 600 "$ARCHIVE"
rm -rf "$DEST/$NAME"
trap - EXIT INT TERM

note ""
note "Wrote $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1 | tr -d ' '), mode 0600)"
note ""
note "This file contains every message on this server in plaintext, plus the"
note "OIDC signing key and the TURN secret. Encrypt it before it leaves this host."
note ""
note "Prove it restores — do this now, and on a schedule, not after an outage:"
note "  ./backup.sh --verify $ARCHIVE"
note ""
note "Restore steps are in README.md, 'Backup and restore'."
