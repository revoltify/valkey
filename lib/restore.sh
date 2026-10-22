#!/bin/sh

archive_is_valid() {
    expected=$(s3_expected_sha256 "$1")
    if [ -n "$expected" ] && [ "$(sha256_of "$2")" != "$expected" ]; then
        log "$1 checksum mismatch"
        return 1
    fi
    gzip -t "$2" 2>/dev/null || { log "$1 is not a valid gzip archive"; return 1; }
}

download_backup() {
    log "downloading $1"
    s3_download "$1" "$2" || { log "download of $1 failed"; return 1; }
    archive_is_valid "$1" "$2"
}

unpack_snapshot() {
    gunzip -c "$1" > "$2" || { log "could not unpack $3"; return 1; }
    valkey-check-rdb "$2" > /dev/null 2>&1 || { log "$3 is not a valid RDB snapshot"; return 1; }
}

newest_backup() {
    backups=$(backup_names) || { log "cannot list backups in s3"; return 1; }
    printf '%s\n' "$backups" | tail -n 1
}
