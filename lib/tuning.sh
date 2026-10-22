#!/bin/sh

MAX_IO_THREADS=8
CGROUP_ROOT=/sys/fs/cgroup

host_memory_bytes() {
    kilobytes=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    printf '%s' "$((kilobytes * 1024))"
}

own_cgroup_dirs() {
    path=$(sed -n 's/^0:://p' /proc/self/cgroup)
    while true; do
        [ -d "$CGROUP_ROOT$path" ] && printf '%s\n' "$CGROUP_ROOT$path"
        [ -z "$path" ] || [ "$path" = "/" ] && return 0
        path=${path%/*}
    done
}

smallest_cgroup_memory_limit() {
    for dir in $(own_cgroup_dirs) "$CGROUP_ROOT/memory"; do
        cat "$dir/memory.max" "$dir/memory.limit_in_bytes" 2>/dev/null
    done | grep -E '^[0-9]+$' | sort -n | head -n 1
}

container_memory_bytes() {
    host=$(host_memory_bytes)
    limit=$(smallest_cgroup_memory_limit)
    if [ -z "$limit" ] || [ "$limit" -ge "$host" ]; then
        log "no cgroup memory limit below MemTotal found, sizing from MemTotal ($host bytes)"
        printf '%s' "$host"
        return
    fi
    printf '%s' "$limit"
}

cgroup_cpu_quotas() {
    for dir in $(own_cgroup_dirs); do
        cat "$dir/cpu.max" 2>/dev/null
    done
    if [ -r "$CGROUP_ROOT/cpu/cpu.cfs_quota_us" ]; then
        printf '%s %s\n' "$(cat "$CGROUP_ROOT/cpu/cpu.cfs_quota_us")" "$(cat "$CGROUP_ROOT/cpu/cpu.cfs_period_us")"
    fi
}

container_cpus() {
    online=$(nproc)
    limited=$(cgroup_cpu_quotas | awk '$1 ~ /^[0-9]+$/ && $1 > 0 { cpus = int(($1 + $2 - 1) / $2); print cpus }' | sort -n | head -n 1)
    [ -n "$limited" ] && [ "$limited" -lt "$online" ] && printf '%s' "$limited" || printf '%s' "$online"
}

auto_maxmemory() {
    printf '%s' "$(($(container_memory_bytes) * VALKEY_MAXMEMORY_PERCENT / 100))"
}

auto_io_threads() {
    threads=$(($(container_cpus) * 3 / 4))
    [ "$threads" -lt 1 ] && threads=1
    [ "$threads" -gt "$MAX_IO_THREADS" ] && threads=$MAX_IO_THREADS
    printf '%s' "$threads"
}

tuned_directives() {
    printf 'maxmemory %s\n' "${VALKEY_MAXMEMORY:-$(auto_maxmemory)}"
    printf 'io-threads %s\n' "${VALKEY_IO_THREADS:-$(auto_io_threads)}"
}

env_directives() {
    env | awk -F '=' '/^VALKEY_CONFIG_[A-Z0-9_]+=/ {
        name = substr($1, 15)
        gsub("_", "-", name)
        print tolower(name), substr($0, length($1) + 2)
    }'
}

reserved_env_directives() {
    env_directives | awk '{ print $1 }' \
        | grep -xE 'port|dir|dbfilename|appendfilename|appenddirname|requirepass|include|daemonize|unixsocket|logfile|bind|replicaof|slaveof|replica-announce-ip|masterauth|masteruser'
}
