#!/bin/sh
# Consistent, offline-safe backup of a running BSFChat deployment.
#
#   ./backup.sh                 write a new archive into ./backups
#   ./backup.sh /mnt/backups    write it somewhere else
#   ./backup.sh --verify FILE   prove that archive actually restores
#   ./backup.sh --no-media      skip uploaded media (much smaller, lossy)
#
# Retention (see "Retention" below, and README.md "Retention and rotation"):
#
#   ./backup.sh --prune-older-than 30
#                               write an archive, then delete archives that are
#                               30 or more days old
#   ./backup.sh --prune-only --prune-older-than 30 --dry-run
#                               change nothing; list exactly what retention
#                               would delete. Read-only; safe to run any time
#   ./backup.sh --require-private-dest
#                               refuse to run at all if the destination
#                               directory is readable by anyone but its owner
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
#
# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------
# --prune-older-than exists because the privacy policy states a retention
# period for backups, and a stated period that nothing enforces is worse than
# no statement at all. It is a flag rather than a `find -delete` in a systemd
# unit so that the thing which deletes your only copy of every message on the
# server is reviewable, has a --dry-run, and lives next to the code that
# decides what an archive is called.
#
# What it deletes: files directly in the destination directory (never
# recursively, never through a symlink) whose names match the
# bsfchat-<stamp>.tar.gz pattern this script writes, and nothing else. An
# encrypted .tar.gz.age sitting beside them does not match and is left alone —
# which also means it is not retained by anything either. Age comes from the
# filesystem mtime, not from the stamp in the name, so an archive that was
# copied or restored into this directory counts as new from the moment it
# landed. The stamp in the name is the real backup time; cross-check with it.
#
# The off-by-one, said out loud: --prune-older-than 30 deletes archives that
# are 30 or more days old, so what survives is everything from the last 30
# days. With one backup a night that is 30 archives, and nothing retained is
# 30 days old. That is the reading that matches a policy sentence saying
# "thirty days".
#
# WHERE IT RUNS IN THE ORDER MATTERS. systemd/bsfchat-backup.service prunes
# BEFORE it takes the night's backup, not after. That is deliberate and it is
# the opposite of what "clean up after yourself" suggests:
#
#   * retention is a privacy obligation, so it must not be conditional on the
#     backup succeeding. Pruning afterwards means a backup that fails for a
#     month — a full disk, a moved data directory — silently stops deleting
#     anything, and the deployment quietly holds archives past the period the
#     policy commits to, with nothing saying so;
#   * pruning first also frees the space the new archive needs, so a disk that
#     filled up recovers on the next run instead of deadlocking (backup fails
#     for want of space -> prune never runs -> space never freed).
#
# The cost is that if backups fail every night for longer than the retention
# period, retention eventually deletes the last one. That is the correct
# outcome for the policy and a loud one operationally: the unit is in `failed`
# state every night for a month first. Watch it (`systemctl list-timers`,
# `systemctl --failed`) rather than trading the privacy guarantee away for it.
#
# --require-private-dest is what makes automating this defensible at all. One
# archive taken by hand and encrypted off the host is a different risk from
# thirty plaintext copies of every message, the OIDC signing key and the TURN
# secret accumulating next to the service that produced them. The flag refuses
# to run when the destination directory gives any group or other bit away, so
# an automated schedule cannot quietly turn a 0755 directory into a month-long
# exposure. It is not on by default because `./backup.sh /tmp` — the
# encrypt-and-shred recipe above — is a legitimate one-shot into a 1777
# directory. Automation opts in; the timer passes it.

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
# A while loop rather than `for arg in "$@"`, because --prune-older-than takes
# a value and the old loop could not consume the next argument: it would have
# read the number as the destination directory and written the archive into
# ./30.
WITH_MEDIA=1
DEST=backups
PRUNE_DAYS=""
PRUNE_ONLY=0
DRY_RUN=0
REQUIRE_PRIVATE_DEST=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-media)            WITH_MEDIA=0 ;;
        --prune-only)          PRUNE_ONLY=1 ;;
        --dry-run)             DRY_RUN=1 ;;
        --require-private-dest) REQUIRE_PRIVATE_DEST=1 ;;
        --prune-older-than)
            shift
            [ "$#" -gt 0 ] || die "--prune-older-than needs a number of days."
            PRUNE_DAYS="$1" ;;
        --prune-older-than=*)  PRUNE_DAYS="${1#*=}" ;;
        --*)                   die "Unknown option: $1" ;;
        *)                     DEST="$1" ;;
    esac
    shift
done

# Validate the retention period before anything is deleted with it. An empty
# or non-numeric value must never reach `find -mtime`, where "+-1" or "+abc"
# is an error on GNU find but has been a silent match-everything on others.
if [ -n "$PRUNE_DAYS" ]; then
    case "$PRUNE_DAYS" in
        ''|*[!0-9]*) die "--prune-older-than takes a whole number of days, got: $PRUNE_DAYS" ;;
    esac
    [ "$PRUNE_DAYS" -ge 1 ] ||
        die "--prune-older-than 0 would delete the backup this script just took.
         If you want no retained backups, do not run this script."
fi

if [ "$PRUNE_ONLY" = 1 ] && [ -z "$PRUNE_DAYS" ]; then
    die "--prune-only needs --prune-older-than DAYS. Refusing to guess a
         retention period for a directory full of copies of the server."
fi

if [ "$DRY_RUN" = 1 ] && [ "$PRUNE_ONLY" = 0 ]; then
    die "--dry-run only covers retention, not the backup itself. Taking a
         backup has no dry run — it either writes an archive or it does not.
         For a read-only report of what retention would delete:
           ./backup.sh --prune-only --prune-older-than DAYS --dry-run"
fi

# ---------------------------------------------------------------------------
# Is the destination fit to hold this?
# ---------------------------------------------------------------------------
# Every archive in here is a complete plaintext copy of the server: every
# message, the OIDC signing key that mints tokens for any account, and the
# TURN secret. A directory that is 0755 hands all of that to every local user,
# and a nightly schedule turns that from one mistake into a standing one.
#
# Warn always, refuse under --require-private-dest. See "Retention" in the
# header for why automation opts in rather than this being unconditional.
#
# Only an existing directory is checked: one this script creates is created
# under `umask 077` a few lines further down, so it is 0700 by construction.
check_dest_private() {
    [ -d "$DEST" ] || return 0
    # ls -l may append '.' or '+' for SELinux labels or ACLs, so take a fixed
    # width: chars 5-10 are the group and other triplets.
    # shellcheck disable=SC2012  # one directory we name ourselves, not a listing
    mode=$(ls -ld "$DEST" | cut -c1-10)
    case "$mode" in
        ????------) return 0 ;;
    esac
    if [ "$REQUIRE_PRIVATE_DEST" = 1 ]; then
        die "$DEST is $mode — readable or writable by more than its owner, and
         every file in it is a full plaintext copy of this server.

         Refusing to run because --require-private-dest was passed (the
         systemd unit passes it, so this is what a failed nightly backup
         looks like when the directory's mode has drifted).

         Fix it:
           chmod 0700 $DEST
           ls -ld $DEST

         Then check what is already in there: anything written while the
         directory was $mode has been readable by every local user for as
         long as it has existed."
    fi
    note "WARNING: $DEST is $mode, so more than its owner can read it, and"
    note "         every archive in it is a full plaintext copy of this"
    note "         server — messages, OIDC signing key, TURN secret."
    note "         Fix with: chmod 0700 $DEST"
}

# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------
# --prune-older-than N deletes archives N or more days old, leaving the last N
# days. The -1 is the whole reason this is a function with a comment on it:
# find's `-mtime +n` means "age, truncated to whole days, is greater than n",
# so `-mtime +29` is the set aged 30 days and up. See "Retention" in the
# header for why that is the reading a policy sentence wants.
#
# Deliberately narrow: -maxdepth 1 so a nested directory of something else is
# never touched, -type f so the .partial staging directory cannot match, and a
# -name pattern that only matches what this script itself writes. An encrypted
# bsfchat-<stamp>.tar.gz.age does not match on purpose — it is also not
# retained by anything, which is worth knowing if you encrypt in place.
prune() {
    days="$1"
    threshold=$(( days - 1 ))

    [ -d "$DEST" ] || { note "retention: $DEST does not exist yet, nothing to prune."; return 0; }

    # `|| true` inside the substitution: find exits non-zero on an unreadable
    # entry, and `set -e` would take the whole script down mid-retention.
    victims=$(find "$DEST" -maxdepth 1 -type f -name 'bsfchat-*.tar.gz' \
                   -mtime "+$threshold" 2>/dev/null | sort || true)
    kept=$(find "$DEST" -maxdepth 1 -type f -name 'bsfchat-*.tar.gz' 2>/dev/null | wc -l | tr -d ' ' || true)

    if [ -z "$victims" ]; then
        note "retention: nothing is $days days old or older in $DEST ($kept archive(s) held)."
        return 0
    fi

    n=0
    for f in $victims; do
        n=$(( n + 1 ))
        if [ "$DRY_RUN" = 1 ]; then
            note "would delete: $f"
        else
            rm -f "$f" || die "could not delete $f — retention did not complete.
         Check the mode and ownership of $DEST."
            note "deleted: $f"
        fi
    done

    remaining=$(( kept - n ))
    if [ "$DRY_RUN" = 1 ]; then
        note ""
        note "DRY RUN: nothing was deleted. $n of $kept archive(s) are $days days"
        note "         old or older. Drop --dry-run to delete them."
        return 0
    fi

    note ""
    note "retention: deleted $n archive(s) $days days old or older; $remaining left."
    # Worth saying out loud rather than leaving to be inferred from a count of
    # zero: this is what a schedule that has been failing for longer than the
    # retention period looks like on the day it catches up.
    if [ "$remaining" = 0 ]; then
        note ""
        note "WARNING: there are now NO backups in $DEST."
        note "         Everything in it was past the $days-day retention period,"
        note "         which means no backup has succeeded in that long. Check:"
        note "           systemctl status bsfchat-backup.service"
        note "           journalctl -u bsfchat-backup.service --since '-$days days'"
    fi
}

check_dest_private

if [ "$PRUNE_ONLY" = 1 ]; then
    prune "$PRUNE_DAYS"
    exit 0
fi

[ -f data/server/bsfchat.db ] || die "data/server/bsfchat.db does not exist. Is this the right
         directory, and has the server ever started?"

# ---------------------------------------------------------------------------
# Will it fit?
# ---------------------------------------------------------------------------
# A backup that fills the disk does not just fail, it takes the service with
# it: the server cannot write its database and nginx cannot write its logs.
# That risk arrived with the nightly schedule — one archive taken by hand, with
# somebody watching the output, is not the same as thirty accumulating.
#
# Both the staging copy and the finished .tar.gz exist at once, so the ceiling
# is roughly twice the uncompressed size of what goes in (the archive
# compresses, media mostly does not). That doubling makes this a deliberate
# over-estimate.
#
# A warning, not a refusal, and that is a real choice: this is an estimate of
# an upper bound, and a hard failure here would refuse backups that would
# actually have fitted. The thing that keeps the disk from filling is retention
# running first — see "Retention" in the header — not this check. Size the disk
# with the commands in README.md, "Retention and rotation".
check_space() {
    command -v du >/dev/null 2>&1 || return 0
    command -v df >/dev/null 2>&1 || return 0

    need_kb=0
    for src in data/server/bsfchat.db data/identity/identity.db; do
        [ -f "$src" ] || continue
        sz=$(du -sk "$src" 2>/dev/null | cut -f1) || continue
        need_kb=$(( need_kb + sz ))
    done
    if [ "$WITH_MEDIA" = 1 ] && [ -d data/server/media ]; then
        sz=$(du -sk data/server/media 2>/dev/null | cut -f1) || sz=0
        need_kb=$(( need_kb + sz ))
    fi
    need_kb=$(( need_kb * 2 ))
    [ "$need_kb" -gt 0 ] || return 0

    # df the destination if it exists, otherwise the directory it will be
    # created in — on a first run $DEST does not exist yet and df errors out,
    # which used to skip this check silently on exactly the run where the disk
    # has never held an archive before.
    probe="$DEST"
    [ -d "$probe" ] || probe=$(dirname "$DEST")
    [ -d "$probe" ] || return 0

    # -P for the portable single-line-per-filesystem format; without it a long
    # device name wraps onto its own line and the field numbering shifts.
    avail_kb=$(df -Pk "$probe" 2>/dev/null | awk 'NR==2 {print $4}') || return 0
    case "${avail_kb:-}" in
        ''|*[!0-9]*) return 0 ;;
    esac

    # Round the requirement up: a small deployment reporting "needs up to 0MB"
    # reads like the check is broken.
    note "space: this run needs up to $(( (need_kb + 1023) / 1024 ))MB, $(( avail_kb / 1024 ))MB free on $probe"
    [ "$avail_kb" -ge "$need_kb" ] && return 0

    note "WARNING: that may not fit, and a full disk stops the server writing"
    note "         its database as well as stopping this backup. Either free"
    note "         space, lower the retention period, or move the nightly"
    note "         backup to --no-media and take full ones less often. See"
    note "         \"Retention and rotation\" in README.md."
}

check_space

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
    # Confirm the copy is a database and not, say, 40MB of zeroes, before
    # calling this a backup.
    #
    # Note the side effect, because the archive shows it: .backup writes a
    # single checkpointed file, but that file inherits WAL journal mode from
    # the source, and this integrity_check opens it read-write, which
    # materialises -wal and -shm beside it. Each database is therefore three
    # files by the time the staging directory is tarred, not one. Left alone
    # on purpose:
    #   * the -wal is 0 bytes. integrity_check only reads, so nothing is
    #     committed through this connection and no transaction hides in it;
    #   * -shm is an index into the -wal, rebuilt on the next open and never
    #     authoritative;
    #   * both are created under this script's umask 077 inside the 0700
    #     staging directory, so they expose nothing the archive does not.
    # A restore is identical either way: a WAL database opened against an
    # empty -wal is the ordinary case. Deleting them here would buy a tidier
    # tar and one more thing to get wrong.
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

# Retention runs AFTER the archive here, which is the opposite of the systemd
# unit. Both are right for what they are: a person running this by hand wants
# tonight's backup on disk before anything is deleted, and if the run failed
# they are looking at the error. A schedule cannot rely on anyone looking, so
# it prunes first and keeps the privacy guarantee independent of whether the
# backup worked — see "Retention" in the header.
if [ -n "$PRUNE_DAYS" ]; then
    note ""
    note "--- retention ($PRUNE_DAYS days) ---"
    prune "$PRUNE_DAYS"
    note ""
fi
