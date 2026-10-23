#!/bin/sh

NODE_ENV_FILE=/etc/node.env

load_node_env() {
    [ -r "$NODE_ENV_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in *=*) ;; *) continue ;; esac
        key=${line%%=*}
        case "$key" in '' | [0-9]* | *[!A-Za-z0-9_]*) continue ;; esac
        export "$key=${line#*=}"
    done < "$NODE_ENV_FILE"
}

load_node_env

DATA_DIR=/data
BACKUP_PATH="${BACKUP_PATH:-valkey}"
BACKUP_PATH_PATTERN='[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*'
BACKUP_NAME_PATTERN='^dump-[0-9]{8}T[0-9]{6}Z\.rdb\.gz$'
BACKUP_TMP_DIR="${BACKUP_TMP_DIR:-/tmp}"

: "${BACKUP_ENABLED:=true}"
: "${RESTORE_ON_EMPTY:=true}"
: "${BACKUP_INTERVAL_SECONDS:=3600}"
: "${BACKUP_RETRY_SECONDS:=300}"
: "${BACKUP_RETENTION:=168}"
: "${BACKUP_SNAPSHOT_TIMEOUT:=3600}"
: "${VALKEY_MAXMEMORY_PERCENT:=70}"

export VALKEYCLI_AUTH="${VALKEY_PASSWORD:-}"

log() {
    printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0")" "$*" >&2
}

fail() {
    log "ERROR: $*"
    exit 1
}

value_of() {
    eval "printf '%s' \"\${$1:-}\""
}

require_env() {
    for variable in "$@"; do
        [ -n "$(value_of "$variable")" ] || fail "$variable is required"
    done
}

require_boolean() {
    case "$(value_of "$1")" in
        true | false) ;;
        *) fail "$1 must be true or false" ;;
    esac
}

require_integer_at_least() {
    value=$(value_of "$1")
    case "$value" in
        '' | *[!0-9]*) fail "$1 must be a whole number" ;;
    esac
    [ "$value" -ge "$2" ] || fail "$1 must be at least $2"
}

require_matching() {
    printf '%s' "$(value_of "$1")" | grep -Eq "^$2\$" || fail "${3:-$1 contains unsupported characters}"
}

distinct_characters_in() {
    printf '%s' "$1" | fold -w 1 | sort -u | wc -l | tr -d ' '
}

validate_password() {
    require_env VALKEY_PASSWORD
    require_matching VALKEY_PASSWORD '[A-Za-z0-9_-]{32,}' 'VALKEY_PASSWORD must be at least 32 characters of A-Z a-z 0-9 _ -'
    [ "$(distinct_characters_in "$VALKEY_PASSWORD")" -ge 10 ] || fail "VALKEY_PASSWORD is too predictable, generate one with: openssl rand -hex 32"
}

drop_privileges() {
    [ "$(id -u)" = "0" ] || return 0
    [ "$(stat -c %U "$DATA_DIR")" = "valkey" ] || chown -R valkey:valkey "$DATA_DIR"
    chmod 700 "$DATA_DIR"
    exec su-exec valkey "$@"
}

validate_backup_env() {
    s3_require_env
    require_integer_at_least BACKUP_INTERVAL_SECONDS 60
    require_integer_at_least BACKUP_RETRY_SECONDS 1
    require_integer_at_least BACKUP_RETENTION 1
    require_integer_at_least BACKUP_SNAPSHOT_TIMEOUT 1
}

valkey_ping() {
    valkey-cli PING 2>/dev/null | grep -q '^PONG'
}

info_field() {
    valkey-cli INFO "$1" | tr -d '\r' | sed -n "s/^$2://p"
}

persistence_field() {
    info_field persistence "$1"
}

is_primary() {
    [ "$(info_field replication role)" = "master" ]
}

is_synced_replica() {
    replication=$(valkey-cli INFO replication | tr -d '\r')
    printf '%s\n' "$replication" | grep -qx 'role:slave' && printf '%s\n' "$replication" | grep -qx 'master_link_status:up'
}

total_keys() {
    valkey-cli INFO keyspace | tr -d '\r' | sed -n 's/^db[0-9]*:keys=\([0-9]*\).*/\1/p' | awk '{ total += $1 } END { print total + 0 }'
}

sha256_of() {
    sha256sum "$1" | cut -d ' ' -f 1
}

size_of() {
    wc -c < "$1" | tr -d ' '
}

backup_names() {
    objects=$(s3_list) || return 1
    printf '%s\n' "$objects" | grep -E "$BACKUP_NAME_PATTERN" | sort
}

use_restore_path() {
    require_matching RESTORE_PATH "$BACKUP_PATH_PATTERN" 'RESTORE_PATH must be an S3 path such as valkey/old, without . or .. segments'
    BACKUP_PATH=$RESTORE_PATH
}

restore_source() {
    [ -z "${RESTORE_PATH:-}" ] || use_restore_path
    [ -z "${RESTORE_BACKUP:-}" ] || printf '%s' "$RESTORE_BACKUP" | grep -Eq "$BACKUP_NAME_PATTERN" \
        || fail "RESTORE_BACKUP must be a backup name as printed by list-backups"
}

restore_candidates() {
    [ -n "${RESTORE_BACKUP:-}" ] || { backup_names; return; }
    printf '%s\n' "$RESTORE_BACKUP"
}

backup_epoch() {
    stamp=${1#dump-}
    date -u -D '%Y%m%dT%H%M%SZ' -d "${stamp%.rdb.gz}" +%s
}

. /usr/local/lib/valkey-backup/s3.sh
