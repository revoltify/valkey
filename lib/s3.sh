#!/bin/sh

S3_REGION="${S3_REGION:-us-east-1}"
S3_ALLOW_HTTP="${S3_ALLOW_HTTP:-false}"
S3_CREDENTIAL_PATTERN='[A-Za-z0-9/+=._-]+'

s3_require_env() {
    require_env S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
    require_matching S3_ACCESS_KEY_ID "$S3_CREDENTIAL_PATTERN"
    require_matching S3_SECRET_ACCESS_KEY "$S3_CREDENTIAL_PATTERN"
    require_matching S3_REGION '[a-z0-9-]+'
    require_matching S3_BUCKET '[A-Za-z0-9.-]+'
    require_boolean S3_ALLOW_HTTP
    case "$S3_ENDPOINT" in
        https://*) ;;
        http://*) [ "$S3_ALLOW_HTTP" = "true" ] || fail "S3_ENDPOINT must use https://" ;;
        *) fail "S3_ENDPOINT must start with https://" ;;
    esac
}

bucket_url() {
    printf '%s/%s' "${S3_ENDPOINT%/}" "$S3_BUCKET"
}

object_url() {
    printf '%s/%s/%s' "$(bucket_url)" "$BACKUP_PATH" "$1"
}

uri_encode() {
    jq -rn --arg value "$1" '$value | @uri'
}

xml_values() {
    grep -o "<$1>[^<]*</$1>" | sed "s#</*$1>##g"
}

s3_curl() {
    printf 'user = "%s:%s"\naws-sigv4 = "aws:amz:%s:s3"\n' "$S3_ACCESS_KEY_ID" "$S3_SECRET_ACCESS_KEY" "$S3_REGION" \
        | curl --config - --fail --silent --show-error \
            --connect-timeout 10 --speed-limit 1024 --speed-time 60 \
            --retry 3 --retry-delay 5 "$@"
}

s3_list() {
    token=""
    while true; do
        query="list-type=2&prefix=$(uri_encode "$BACKUP_PATH/")"
        [ -n "$token" ] && query="$query&continuation-token=$(uri_encode "$token")"
        page=$(s3_curl "$(bucket_url)?$query") || return 1
        printf '%s' "$page" | xml_values Key | sed "s#^$BACKUP_PATH/##"
        [ "$(printf '%s' "$page" | xml_values IsTruncated)" = "true" ] || return 0
        token=$(printf '%s' "$page" | xml_values NextContinuationToken)
        [ -n "$token" ] || { log "listing truncated without continuation token"; return 1; }
    done
}

s3_head() {
    s3_curl --head "$(object_url "$1")" | tr -d '\r'
}

header_value() {
    awk -F ': ' -v name="$1" 'tolower($1) == name { print $2 }'
}

s3_upload() {
    checksum=$(sha256_of "$1")
    s3_curl --header "x-amz-content-sha256: $checksum" --header "x-amz-meta-sha256: $checksum" \
        --header "x-amz-meta-keys: $3" \
        --header 'Content-Type: application/octet-stream' \
        --upload-file "$1" "$(object_url "$2")" > /dev/null || return 1
    remote_size=$(s3_head "$2" | header_value content-length)
    [ "$remote_size" = "$(size_of "$1")" ] || { log "uploaded $2 size $remote_size does not match local file"; return 1; }
}

s3_expected_sha256() {
    s3_head "$1" | header_value x-amz-meta-sha256
}

s3_recorded_keys() {
    s3_head "$1" | header_value x-amz-meta-keys
}

s3_download() {
    s3_curl --output "$2" "$(object_url "$1")"
}

s3_delete() {
    s3_curl --request DELETE "$(object_url "$1")" > /dev/null
}
