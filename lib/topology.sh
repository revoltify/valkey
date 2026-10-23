#!/bin/sh

VALKEY_PORT=6379
SENTINEL_PORT=26379
SENTINEL_TIMEOUT_SECONDS=3
FAILOVER_MINIMUM_NODES=3
IPV4_PATTERN='([0-9]{1,3}\.){3}[0-9]{1,3}'

: "${SENTINEL_MASTER_NAME:=main}"
: "${SENTINEL_QUORUM:=2}"
: "${VALKEY_INITIAL_PRIMARY:=false}"

sentinel_enabled() {
    [ -n "${SENTINEL_HOSTS:-}" ]
}

validate_topology_env() {
    require_env VALKEY_PRIVATE_IP
    require_matching VALKEY_PRIVATE_IP "$IPV4_PATTERN" 'VALKEY_PRIVATE_IP must be an IPv4 address'
    validate_read_only_env
    sentinel_enabled || return 0
    require_ipv4_list SENTINEL_HOSTS
    require_matching SENTINEL_MASTER_NAME '[A-Za-z0-9_-]+'
    require_integer_at_least SENTINEL_QUORUM 1
    require_boolean VALKEY_INITIAL_PRIMARY
}

read_only_node() {
    [ "${VALKEY_CONFIG_REPLICA_PRIORITY:-}" = "0" ]
}

validate_read_only_env() {
    read_only_node || return 0
    sentinel_enabled || fail "a read-only node (VALKEY_CONFIG_REPLICA_PRIORITY=0) needs SENTINEL_HOSTS to find its primary"
    [ "$VALKEY_INITIAL_PRIMARY" = "false" ] || fail "a read-only node (VALKEY_CONFIG_REPLICA_PRIORITY=0) cannot be VALKEY_INITIAL_PRIMARY"
}

require_ipv4_list() {
    require_matching "$1" "$IPV4_PATTERN(,$IPV4_PATTERN)*" "$1 must be comma-separated IPv4 addresses without spaces"
}

hosts_in() {
    printf '%s\n' "$1" | tr ',' '\n'
}

sentinel_hosts() {
    hosts_in "$SENTINEL_HOSTS"
}

first_sentinel_host() {
    sentinel_hosts | head -n 1
}

primary_known_by() {
    timeout "$SENTINEL_TIMEOUT_SECONDS" valkey-cli -h "$1" -p "$SENTINEL_PORT" SENTINEL get-master-addr-by-name "$SENTINEL_MASTER_NAME" 2>/dev/null \
        | head -n 1 | grep -Ex "$IPV4_PATTERN"
}

known_primary() {
    for host in $(sentinel_hosts); do
        primary_known_by "$host" && return 0
    done
    return 1
}

wait_for_known_primary() {
    until known_primary; do
        log "no sentinel knows a primary yet, retrying in 5s"
        sleep 5
    done
}

primary_address() {
    sentinel_enabled || { printf '%s' "$VALKEY_PRIVATE_IP"; return; }
    known_primary && return
    [ "$VALKEY_INITIAL_PRIMARY" = "true" ] && ! has_local_data && { printf '%s' "$VALKEY_PRIVATE_IP"; return; }
    wait_for_known_primary
}

has_local_data() {
    [ -s "$DATA_DIR/dump.rdb" ] || [ -d "$DATA_DIR/appendonlydir" ]
}

bind_addresses() {
    [ "$VALKEY_PRIVATE_IP" = "0.0.0.0" ] && { printf '0.0.0.0'; return; }
    printf '%s 127.0.0.1' "$VALKEY_PRIVATE_IP"
}

required_replicas_for() {
    [ "$1" -ge "$FAILOVER_MINIMUM_NODES" ] && { printf '1'; return; }
    printf '0'
}

topology_directives() {
    printf 'bind %s\n' "$(bind_addresses)"
    sentinel_enabled || return 0
    printf 'replica-announce-ip %s\n' "$VALKEY_PRIVATE_IP"
    printf 'masterauth "%s"\n' "$VALKEY_PASSWORD"
    printf 'min-replicas-to-write %s\n' "$(required_replicas_for "$(sentinel_hosts | wc -l)")"
    printf 'min-replicas-max-lag 10\n'
    [ "$1" = "$VALKEY_PRIVATE_IP" ] || printf 'replicaof %s %s\n' "$1" "$VALKEY_PORT"
}
