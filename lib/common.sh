#!/bin/sh

DATA_DIR=/data
BACKUP_PATH="${BACKUP_PATH:-valkey}"
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

persistence_field() {
    valkey-cli INFO persistence | tr -d '\r' | sed -n "s/^$1://p"
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

backup_epoch() {
    stamp=${1#dump-}
    date -u -D '%Y%m%dT%H%M%SZ' -d "${stamp%.rdb.gz}" +%s
}

. /usr/local/lib/valkey-backup/s3.sh
