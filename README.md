# Valkey with S3 Backups

Production Valkey 9 image for Bunny Magic Containers, with backups to any S3-compatible storage (Bunny Storage S3, Cloudflare R2, AWS S3, Backblaze B2).

- `maxmemory-policy noeviction`: writes fail with `OOM` when memory is full. Keys are never evicted silently.
- AOF (`appendfsync everysec`) is the durability layer; RDB snapshots feed the backups.
- Gzipped RDB snapshots uploaded to S3 on an interval, with retention pruning. An empty dataset is never uploaded, so a wiped or misconfigured instance can't push good backups out of retention.
- On boot the image picks the safest data source: a complete AOF, else `dump.rdb`, else the newest valid backup from S3. A corrupt backup falls back to the previous one. If S3 is unreachable or rejects the credentials, the container refuses to start rather than start empty.
- Auto-tuned from the container's cgroup CPU and memory limits.
- Every Valkey directive can be set through env vars.

## Build

```bash
docker build -t valkey-s3 .
```

## Environment

### Required

| Variable | Description |
|---|---|
| `VALKEY_PASSWORD` | 32+ chars, `A-Z a-z 0-9 _ -` only. Generate with `openssl rand -hex 32`. |
| `S3_ENDPOINT` | `https://` only, e.g. `https://sg-s3.storage.bunnycdn.com`. |
| `S3_REGION` | e.g. `sg` for Bunny, `auto` for R2, `eu-central-1` for AWS. Defaults to `us-east-1`. |
| `S3_BUCKET` | Bucket name. On Bunny this is the storage zone name. |
| `S3_ACCESS_KEY_ID` | On Bunny this is the storage zone name. |
| `S3_SECRET_ACCESS_KEY` | On Bunny this is the storage zone password. |

The S3 values are only required while `BACKUP_ENABLED=true`.

### Tuning

| Variable | Default | Description |
|---|---|---|
| `VALKEY_MAXMEMORY_PERCENT` | `70` | Percent of container memory for `maxmemory` (1–95). The rest is headroom for fork copy-on-write during BGSAVE and AOF rewrite. |
| `VALKEY_MAXMEMORY` | auto | Fixed value instead, e.g. `24gb`. |
| `VALKEY_IO_THREADS` | auto | Default is 3/4 of CPUs, capped at 8. |

On 8 vCPU / 34 GB this gives `maxmemory` ≈ 23.8 GB and `io-threads 6`. The detected values are logged at startup. If no cgroup memory limit is visible, it sizes from `MemTotal` and logs that.

Under write load, watch `current_cow_peak` in `INFO persistence` during a backup. If it gets close to the 30% headroom, lower `VALKEY_MAXMEMORY_PERCENT`.

### Any Valkey directive

`VALKEY_CONFIG_<NAME>=<value>` becomes `<name> <value>`. Underscores turn into dashes and the name is lowercased.

| Example | Result |
|---|---|
| `VALKEY_CONFIG_MAXCLIENTS=20000` | `maxclients 20000` |
| `VALKEY_CONFIG_SAVE=3600 1 300 100` | `save 3600 1 300 100` (replaces the default `3600 1`) |
| `VALKEY_CONFIG_APPENDFSYNC=always` | `appendfsync always` |
| `VALKEY_CONFIG_MAXMEMORY_POLICY=allkeys-lru` | overrides `noeviction` |

These override `valkey.conf` and the auto-tuned values. `port`, `dir`, `dbfilename`, `appendfilename`, `appenddirname`, `requirepass`, `include`, `daemonize`, `unixsocket` and `logfile` are managed by the image and rejected. Only directive names are logged, never values.

### Backups

| Variable | Default | Description |
|---|---|---|
| `BACKUP_ENABLED` | `true` | `true` or `false`. `false` turns off upload and restore. |
| `BACKUP_INTERVAL_SECONDS` | `3600` | Target time between backups (min 60). Measured from the newest backup in S3, so restarts don't delay it. |
| `BACKUP_RETRY_SECONDS` | `300` | Wait after a failed or skipped backup. |
| `BACKUP_RETENTION` | `168` | Number of backups kept (7 days hourly). |
| `BACKUP_SNAPSHOT_TIMEOUT` | `3600` | Max seconds to wait for the BGSAVE, including time queued behind an AOF rewrite. |
| `BACKUP_PATH` | `valkey` | Folder inside the bucket. |
| `BACKUP_TMP_DIR` | `/tmp` | Where the compressed archive is built. Needs free space about the size of `dump.rdb`. |
| `RESTORE_ON_EMPTY` | `true` | `true` or `false`. Restore the newest valid backup when `/data` holds no data. |
| `S3_ALLOW_HTTP` | `false` | Allow an `http://` endpoint. Only for local testing. |

Backups are named `dump-<UTC timestamp>.rdb.gz`; anything else in the folder is ignored. Only one backup runs at a time. Uploads are signed with AWS SigV4 including the payload SHA-256, and the stored size is checked after upload. On restore, every candidate is checked with `gzip -t` and `valkey-check-rdb` (plus the stored SHA-256 where the provider keeps object metadata; Bunny does not) before it replaces anything.

## Bunny Magic Containers

- Run **exactly one instance in one region**. Extra replicas are separate Valkey servers with different data, and they would prune each other's backups.
- Attach a persistent volume at `/data`, sized at **2–3× the dataset** (about 50–70 GB for 24 GB). BGSAVE and AOF rewrite each write a full copy beside the old one. If the disk fills, Valkey rejects writes.
- Expose port `6379` only to your app. Never expose it publicly. Traffic is not encrypted.
- Give the container its full memory limit (e.g. 34 GB). `maxmemory` is derived from it.
- Stopping is fast. SIGTERM skips the final RDB save (`shutdown-on-sigterm nosave`) because AOF already holds every write up to the last second.
- The healthcheck reports healthy while a restore is running or the dataset is loading, so a long restore isn't killed as unhealthy.

## Operations

Run a backup now:

```bash
docker exec <container> backup
```

Restore a specific point in time: stop the container, empty `/data`, delete newer backups from the S3 folder (or download the wanted file to `/data/dump.rdb` yourself), then start the container again.

Check memory and persistence:

```bash
docker exec <container> sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli INFO memory'
```

```bash
docker exec <container> sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli INFO persistence'
```

Laravel connects with the usual `REDIS_HOST`, `REDIS_PASSWORD` and `REDIS_PORT=6379`. Valkey speaks the same protocol, so `phpredis` and `predis` work unchanged.
