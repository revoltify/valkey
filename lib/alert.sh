#!/bin/sh

ALERT_TIMEOUT_SECONDS=10

node_label() {
    printf '%s %s' "${ALERT_NODE_NAME:-$(hostname)}" "${VALKEY_PRIVATE_IP:-}"
}

alert_channels_configured() {
    [ -n "${ALERT_WEBHOOK_URL:-}" ] || [ -n "${ALERT_TELEGRAM_BOT_TOKEN:-}" ]
}

send_webhook() {
    [ -n "${ALERT_WEBHOOK_URL:-}" ] || return 0
    jq -n --arg text "$1" '{ text: $text, content: $text }' \
        | curl --fail --silent --show-error --max-time "$ALERT_TIMEOUT_SECONDS" \
            --header 'Content-Type: application/json' --data @- "$ALERT_WEBHOOK_URL" > /dev/null
}

send_telegram() {
    [ -n "${ALERT_TELEGRAM_BOT_TOKEN:-}" ] || return 0
    curl --fail --silent --show-error --max-time "$ALERT_TIMEOUT_SECONDS" \
        --data-urlencode "chat_id=$ALERT_TELEGRAM_CHAT_ID" --data-urlencode "text=$1" \
        "https://api.telegram.org/bot$ALERT_TELEGRAM_BOT_TOKEN/sendMessage" > /dev/null
}

alert() {
    message="[$(node_label)] $*"
    log "$message"
    alert_channels_configured || return 0
    delivered=false
    send_webhook "$message" && [ -n "${ALERT_WEBHOOK_URL:-}" ] && delivered=true
    send_telegram "$message" && [ -n "${ALERT_TELEGRAM_BOT_TOKEN:-}" ] && delivered=true
    [ "$delivered" = "true" ] || { log "WARNING: alert not delivered, retrying next check"; return 1; }
}

send_heartbeat() {
    [ -n "${HEARTBEAT_URL:-}" ] || return 0
    curl --fail --silent --max-time "$ALERT_TIMEOUT_SECONDS" "$HEARTBEAT_URL" > /dev/null || log "WARNING: heartbeat ping failed"
}
