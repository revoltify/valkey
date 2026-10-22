FROM valkey/valkey:9.0-alpine@sha256:187679e3bd4036959631e3f03983ab2ba503ab21e6fd0454d508e909db2ee989

RUN apk add --no-cache curl~8.22 haproxy~3.4 jq~1.8 lego~4.35 socat~1.8 su-exec~0.3 tini~0.19 \
    && chmod 700 /data

COPY valkey.conf /usr/local/etc/valkey/valkey.conf
COPY lib/ /usr/local/lib/valkey-backup/
COPY --chmod=755 bin/entrypoint bin/sentinel-entrypoint bin/primary-probe bin/primary-status bin/tls-proxy bin/generate-certs bin/backup bin/restore-latest bin/healthcheck /usr/local/bin/

ENV VALKEY_CONFIG_SAVE="3600 1" \
    VALKEY_MAXMEMORY_PERCENT=70 \
    BACKUP_ENABLED=true \
    BACKUP_INTERVAL_SECONDS=3600 \
    BACKUP_RETRY_SECONDS=300 \
    BACKUP_RETENTION=168 \
    BACKUP_SNAPSHOT_TIMEOUT=3600 \
    RESTORE_ON_EMPTY=true \
    BACKUP_PATH=valkey \
    SENTINEL_MASTER_NAME=main \
    SENTINEL_QUORUM=2 \
    VALKEY_INITIAL_PRIMARY=false \
    PRIMARY_PROBE_PORT=8080 \
    TLS_PROXY_PORT=6380 \
    TLS_CLIENT_VERIFY=required \
    ACME_STAGING=false

VOLUME /data
EXPOSE 6379 6380 26379 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=3 CMD ["healthcheck"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/sbin/tini", "--", "entrypoint"]
