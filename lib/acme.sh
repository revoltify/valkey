#!/bin/sh

ACME_DIR=/acme
ACME_RENEW_DAYS=30
ACME_STAGING_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory
ACME_DNS_RESOLVERS=1.1.1.1:53

: "${ACME_STAGING:=false}"

acme_enabled() {
    [ -n "${ACME_DOMAIN:-}" ]
}

validate_acme_env() {
    acme_enabled || return 0
    require_matching ACME_DOMAIN '([a-z0-9-]+\.)+[a-z]{2,}' 'ACME_DOMAIN must be a lowercase domain name, e.g. valkey.example.com'
    require_matching ACME_EMAIL '[^@ ]+@[^@ ]+\.[^@ ]+' 'ACME_EMAIL must be an email address'
    require_env CF_DNS_API_TOKEN
    require_boolean ACME_STAGING
}

prepare_acme_dir() {
    mkdir -p "$ACME_DIR"
    [ "$(stat -c %U "$ACME_DIR")" = "valkey" ] || chown -R valkey:valkey "$ACME_DIR"
    chmod 700 "$ACME_DIR"
}

acme_certificate() {
    printf '%s/lego/certificates/%s.crt' "$ACME_DIR" "$ACME_DOMAIN"
}

acme_key() {
    printf '%s/lego/certificates/%s.key' "$ACME_DIR" "$ACME_DOMAIN"
}

acme_certificate_ready() {
    [ -s "$(acme_certificate)" ] && [ -s "$(acme_key)" ]
}

lego_with_account() {
    set -- --accept-tos --email "$ACME_EMAIL" --dns cloudflare --dns.resolvers "$ACME_DNS_RESOLVERS" \
        --domains "$ACME_DOMAIN" --path "$ACME_DIR/lego" "$@"
    [ "$ACME_STAGING" = "true" ] && set -- --server "$ACME_STAGING_SERVER" "$@"
    lego "$@"
}

renew_acme_certificate() {
    if acme_certificate_ready; then
        lego_with_account renew --days "$ACME_RENEW_DAYS" --no-random-sleep > "$ACME_DIR/lego.log" 2>&1
    else
        log "requesting a Let's Encrypt certificate for $ACME_DOMAIN through Cloudflare DNS"
        lego_with_account run > "$ACME_DIR/lego.log" 2>&1
    fi || { log "ERROR: Let's Encrypt failed for $ACME_DOMAIN: $(tail -n 3 "$ACME_DIR/lego.log" | tr '\n' ' ')"; return 1; }
}

write_serving_certificate() {
    serving="$ACME_DIR/serving.pem"
    candidate="$serving.new"
    if acme_certificate_ready; then
        cat "$(acme_certificate)" "$(acme_key)" > "$candidate"
    else
        cat "$1" > "$candidate"
    fi
    chmod 600 "$candidate"
    cmp -s "$candidate" "$serving" && { rm -f "$candidate"; return 1; }
    mv "$candidate" "$serving"
}
