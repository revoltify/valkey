# Valkey with S3 Backups and Sentinel HA

Production Valkey 9 image for plain VPS (DigitalOcean, OVH, Hetzner…). Runs as a single node or as a horizontally scalable Sentinel group, reachable from anywhere through one TLS endpoint, with backups to any S3-compatible storage (Bunny Storage S3, Cloudflare R2, AWS S3, Backblaze B2). Built for Laravel Horizon.

- `maxmemory-policy noeviction`: writes fail with `OOM` when memory is full. Keys (queued jobs) are never evicted silently.
- AOF (`appendfsync everysec`) is the durability layer; RDB snapshots feed the backups.
- Gzipped RDB snapshots uploaded to S3 on an interval, with retention pruning. Only the current primary uploads. An empty dataset is never uploaded, so a wiped or misconfigured instance can't push good backups out of retention.
- On boot a primary picks the safest data source: a complete AOF, else `dump.rdb`, else the newest valid backup from S3. A corrupt backup falls back to the previous one. If S3 is unreachable or rejects the credentials, the container refuses to start rather than start empty. Replicas never restore; they sync from the primary.
- Optional Sentinel mode: automatic failover in about 10 seconds, nodes can be added or removed.
- A TLS proxy (HAProxy) on every node accepts clients on port 6380 with mutual TLS and forwards them to whichever node is primary. The app sees one host and one password, on any node.
- A primary probe on port 8080 answers `200` only on the current primary; the proxies (or a load balancer) use it to find the primary.
- Auto-tuned from the container's cgroup CPU and memory limits, or the server's memory.
- Every Valkey directive can be set through env vars.

## Architecture

```
App (e.g. Bunny Magic Containers) → valkey.example.com:6380  (DNS: every node's public IP, health-monitored)
                  │ TLS + client certificate
   ┌────────── any node ──────────┐
   │ proxy :6380 (HAProxy, mTLS)  │──→ current primary, found through probe :8080
   │ valkey :6379                 │
   │ sentinel :26379              │   private network: the provider's VPC
   │ probe :8080                  │
   └──────────────────────────────┘
```

Only port 6380 (TLS) is public. Valkey, Sentinel and the probe listen only on the private network. If one node dies, DNS health monitoring drops its IP and the other proxies keep serving; if Valkey fails over, every proxy switches to the new primary within about 2 seconds and closes connections to the old one.

Extra nodes add failover copies, not write throughput. Every write goes to the one primary, so scale throughput by resizing the servers. A single small node handles tens of thousands of commands per second.

## Build

```bash
docker build -t valkey-s3 .
```

## Environment

### Required

| Variable | Description |
|---|---|
| `VALKEY_PASSWORD` | 32+ chars, `A-Z a-z 0-9 _ -` only. Generate with `openssl rand -hex 32`. Same value on every node. |
| `VALKEY_PRIVATE_IP` | The server's private VPC IP. Valkey, Sentinel and the probe bind only to it and `127.0.0.1`. `0.0.0.0` binds everything, only for local testing behind Docker's port mapping. |
| `S3_ENDPOINT` | `https://` only, e.g. `https://sg-s3.storage.bunnycdn.com`. |
| `S3_REGION` | e.g. `sg` for Bunny, `auto` for R2, `eu-central-1` for AWS. Defaults to `us-east-1`. |
| `S3_BUCKET` | Bucket name. On Bunny this is the storage zone name. |
| `S3_ACCESS_KEY_ID` | On Bunny this is the storage zone name. |
| `S3_SECRET_ACCESS_KEY` | On Bunny this is the storage zone password. |

The S3 values are only required while `BACKUP_ENABLED=true`.

### Sentinel HA

| Variable | Default | Description |
|---|---|---|
| `SENTINEL_HOSTS` | unset | Comma-separated VPC IPs of the nodes, initial primary first, e.g. `10.110.0.2,10.110.0.3,10.110.0.4`. Setting it turns on HA mode. Unset means a standalone node. |
| `VALKEY_INITIAL_PRIMARY` | `false` | `true` on exactly one node. Only that node may become primary when no Sentinel knows one yet. |
| `SENTINEL_QUORUM` | `2` | Sentinels that must agree a primary is down. Use a majority of the nodes. Only read when a Sentinel config is first created. |
| `SENTINEL_MASTER_NAME` | `main` | Name of the monitored group. |
| `PRIMARY_PROBE_PORT` | `8080` | Port of the primary probe. |

### TLS proxy

| Variable | Default | Description |
|---|---|---|
| `TLS_PROXY_PORT` | `6380` | Public TLS port. |
| `TLS_CLIENT_VERIFY` | `required` | `required` makes clients present a certificate signed by your CA (mutual TLS). `none` accepts any client and relies on the password alone. |

The proxy reads `server.pem` and `ca.crt` from `./tls`. Create them once with:

```bash
docker run --rm -v ./tls:/certs --entrypoint generate-certs ghcr.io/revoltify/valkey valkey.example.com 203.0.113.10 203.0.113.11 203.0.113.12
```

List every hostname and IP clients use. It creates a private CA (10 years), the server certificate and one client certificate (825 days each). Copy the same `tls` folder to every node, give `ca.crt`, `client.crt` and `client.key` to the app, and keep `ca.key` offline. Re-running keeps existing files; delete `server.*` or `client.*` to reissue them.

### Connection limits

There is no fixed plan limit. The ceilings scale with the server:

| Layer | Limit |
|---|---|
| Valkey `maxclients` | `10000` (raise with `VALKEY_CONFIG_MAXCLIENTS`). Valkey lowers it automatically if the open-file limit is too small. |
| HAProxy | Sized automatically from the open-file limit (`nofile 65535` gives about 32,000 connections). |
| Client buffers | Capped at 10% of `maxmemory` (`maxmemory-clients`), so many idle connections can't push out data. |

Each Horizon process holds one or two connections, so even hundreds of workers stay far below these limits.

In HA mode a node asks the Sentinels who the primary is on every boot. If it is another node, it starts as a replica of it. The primary gets `min-replicas-to-write 1` and `min-replicas-max-lag 10`, so a primary cut off from all replicas stops accepting writes instead of taking jobs that a failover would lose. Override with `VALKEY_CONFIG_MIN_REPLICAS_TO_WRITE=0` if you prefer availability.

### Tuning

| Variable | Default | Description |
|---|---|---|
| `VALKEY_MAXMEMORY_PERCENT` | `70` | Percent of container memory for `maxmemory` (1–95). The rest is headroom for fork copy-on-write during BGSAVE and AOF rewrite. |
| `VALKEY_MAXMEMORY` | auto | Fixed value instead, e.g. `24gb`. |
| `VALKEY_IO_THREADS` | auto | Default is 3/4 of CPUs, capped at 8. |

On 8 vCPU / 34 GB this gives `maxmemory` ≈ 23.8 GB and `io-threads 6`. The detected values are logged at startup. On a server without a container memory limit it sizes from `MemTotal` and logs that. Use a server with at least 2 GB.

Under write load, watch `current_cow_peak` in `INFO persistence` during a backup. If it gets close to the 30% headroom, lower `VALKEY_MAXMEMORY_PERCENT`.

### Any Valkey directive

`VALKEY_CONFIG_<NAME>=<value>` becomes `<name> <value>`. Underscores turn into dashes and the name is lowercased.

| Example | Result |
|---|---|
| `VALKEY_CONFIG_MAXCLIENTS=20000` | `maxclients 20000` |
| `VALKEY_CONFIG_SAVE=3600 1 300 100` | `save 3600 1 300 100` (replaces the default `3600 1`) |
| `VALKEY_CONFIG_APPENDFSYNC=always` | `appendfsync always` |
| `VALKEY_CONFIG_MAXMEMORY_POLICY=allkeys-lru` | overrides `noeviction` |

These override `valkey.conf` and the auto-tuned values. `port`, `bind`, `dir`, `dbfilename`, `appendfilename`, `appenddirname`, `requirepass`, `masterauth`, `masteruser`, `replicaof`, `slaveof`, `replica-announce-ip`, `include`, `daemonize`, `unixsocket` and `logfile` are managed by the image and rejected. Only directive names are logged, never values.

### Backups

| Variable | Default | Description |
|---|---|---|
| `BACKUP_ENABLED` | `true` | `true` or `false`. `false` turns off upload and restore. |
| `BACKUP_INTERVAL_SECONDS` | `3600` | Target time between backups (min 60). Measured from the newest backup in S3, so restarts and failovers don't delay it. `900` suits queues. |
| `BACKUP_RETRY_SECONDS` | `300` | Wait after a failed or skipped backup. |
| `BACKUP_RETENTION` | `168` | Number of backups kept. |
| `BACKUP_SNAPSHOT_TIMEOUT` | `3600` | Max seconds to wait for the BGSAVE, including time queued behind an AOF rewrite. |
| `BACKUP_PATH` | `valkey` | Folder inside the bucket. All nodes of one group share it. |
| `BACKUP_TMP_DIR` | `/tmp` | Where the compressed archive is built. Needs free space about the size of `dump.rdb`. |
| `RESTORE_ON_EMPTY` | `true` | `true` or `false`. Restore the newest valid backup when a primary's `/data` holds no data. |
| `S3_ALLOW_HTTP` | `false` | Allow an `http://` endpoint. Only for local testing. |

Every node runs the backup loop, but only the current primary uploads, so backups follow the primary after a failover. Backups are named `dump-<UTC timestamp>.rdb.gz`; anything else in the folder is ignored. Uploads are signed with AWS SigV4 including the payload SHA-256, and the stored size is checked after upload. On restore, every candidate is checked with `gzip -t` and `valkey-check-rdb` (plus the stored SHA-256 where the provider keeps object metadata; Bunny does not) before it replaces anything.

Replicas protect against a dead server, not against bad writes. A `FLUSHALL` or a buggy deploy reaches every replica within milliseconds. The S3 backups are the way back from those.

## valkeyctl

One command on your own machine sets up and runs a cluster over SSH, with no checkout of this repository:

```bash
curl -fsSL https://raw.githubusercontent.com/revoltify/valkey/main/install.sh | sh
```

```bash
valkeyctl init main
```

`init` asks for single or HA mode, the servers, TLS and backups, then installs everything. Afterwards: `status`, `add-node`, `remove-node`, `replace-node`, `failover`, `upgrade`, `rotate-certs`, `test-failover`, `backup-now`, `env` (Laravel `.env` lines), `certs` (copy the client certificates to the current folder), `cli`, `ssh`, `list`, `self-update`. State lives in `~/.valkeyctl/clusters/`. See [DEPLOY.md](DEPLOY.md) for the full walkthrough.

## Deploy

Step-by-step for DigitalOcean droplets behind a load balancer: [DEPLOY.md](DEPLOY.md). The steps below are the provider-neutral version.

Works on any VPS with Docker (DigitalOcean, OVH, Hetzner…). Use Ubuntu 24.04 or Debian 12 with at least 2 GB RAM, ideally in the region closest to your app. Copy this repository's `host/` folder plus `compose.yaml` and `.env.example` to each server, e.g. `/srv/valkey`.

### 1. Host settings (each server, as root)

```bash
sh host/setup
```

It sets `vm.overcommit_memory=1` (BGSAVE and AOF rewrite can fork safely) and `net.core.somaxconn=1024`, and disables transparent huge pages.

### 2. Private network and firewall

All nodes of a group must share a private network (the provider's VPC, e.g. DigitalOcean VPC, Hetzner Cloud Network, OVH vRack). Use each node's private IP as `VALKEY_PRIVATE_IP` and in `SENTINEL_HOSTS`; replication and Sentinel traffic stays on it.

Restrict access in the provider's firewall: SSH from your IP, everything from the private network, and the TLS port `6380` from your load balancer or app. Containers use host networking, so nothing else is published.

### 3. Certificates

Run `generate-certs` once (see TLS proxy above) and copy the same `tls` folder next to `compose.yaml` on every server.

### 4. DNS

Create one hostname, e.g. `valkey.example.com`, with an A record per server. With Bunny DNS, put them in one record set and turn on health monitoring, so an offline server is dropped from answers. Any live server's proxy reaches the primary, so DNS only needs to know which servers are up.

### 5. Start the nodes
On each server, rename `.env.example` to `.env` and fill it in.

Single node (no `SENTINEL_HOSTS`):

```bash
docker compose up -d
```

Sentinel group: set the same `SENTINEL_HOSTS` everywhere with the initial primary first, and `VALKEY_INITIAL_PRIMARY=true` only on that node. Start the initial primary first, then the others:

```bash
docker compose --profile ha up -d
```

Check:

```bash
docker exec valkey-valkey-1 sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli INFO replication'
```

```bash
docker exec valkey-sentinel-1 sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli -p 26379 SENTINEL get-master-addr-by-name main'
```

### Adding a node
Create a server in the same VPC, run `host/setup`, copy the `tls` folder, add it to DNS, set `.env` with `SENTINEL_HOSTS` (any existing node is enough) and `VALKEY_INITIAL_PRIMARY=false`, then `docker compose --profile ha up -d`. It joins as a replica and its Sentinel is discovered by the others. Raise the quorum to the new majority on every Sentinel:

```bash
docker exec valkey-sentinel-1 sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli -p 26379 SENTINEL SET main quorum 3'
```

### Removing a node
Stop it with `docker compose --profile ha down`, remove it from DNS, then on every remaining Sentinel run `SENTINEL RESET main` so it forgets the node.

### Going from a group to one node
Stop `sentinel` and `valkey` on the replicas. On the primary, remove `SENTINEL_HOSTS` from `.env` and run `docker compose --profile ha down && docker compose up -d`. Laravel keeps using the same hostname.

### Resizing
Single node: resize the server in the provider panel. Valkey is down while the server is off and reloads its AOF on boot. In a group: resize the replicas one at a time, fail over with `SENTINEL FAILOVER main`, then resize the old primary. No downtime beyond the failover.

## Laravel

```env
REDIS_CLIENT=phpredis
REDIS_SCHEME=tls
REDIS_HOST=valkey.example.com
REDIS_PORT=6380
REDIS_PASSWORD=<VALKEY_PASSWORD>
```

With mutual TLS, point phpredis at the certificates in `config/database.php`:

```php
'default' => [
    'scheme' => env('REDIS_SCHEME', 'tcp'),
    'host' => env('REDIS_HOST'),
    'port' => env('REDIS_PORT'),
    'password' => env('REDIS_PASSWORD'),
    'database' => env('REDIS_DB', '0'),
    'context' => [
        'stream' => [
            'cafile' => env('REDIS_TLS_CA'),
            'local_cert' => env('REDIS_TLS_CERT'),
            'local_pk' => env('REDIS_TLS_KEY'),
            'verify_peer' => true,
            'verify_peer_name' => true,
        ],
    ],
],
```

On Bunny Magic Containers, store the three files as base64 env vars and write them to disk when the container starts.

Valkey speaks the Redis protocol, so `phpredis`, `predis` and Horizon work unchanged.

During a failover the proxies close connections to the old primary, so clients see a connection error for a few seconds. Horizon workers exit and Supervisor restarts them on the new primary. Replication is asynchronous, so up to about a second of writes can be lost when the primary dies. For jobs that must never be lost:

- Dispatch after the database commit (`afterCommit`).
- Make jobs idempotent, so a retry or a restored backup can't do harm.
- Keep the source of truth in the database and re-dispatch work that got stuck.

## Operations

Run a backup now (skipped unless the node is the primary):

```bash
docker exec valkey-valkey-1 backup
```

Restore a specific point in time: stop the group, empty `/data` on the initial primary, delete newer backups from the S3 folder (or download the wanted file to `/data/dump.rdb` yourself), start it, then start the others. They sync from it.

Check memory and persistence:

```bash
docker exec valkey-valkey-1 sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli INFO memory'
```

```bash
docker exec valkey-valkey-1 sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli INFO persistence'
```

Test failover:

```bash
docker exec valkey-sentinel-1 sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli -p 26379 SENTINEL FAILOVER main'
```

Stopping is fast. SIGTERM skips the final RDB save (`shutdown-on-sigterm nosave`) because AOF already holds every write up to the last second. The healthcheck reports healthy while a restore is running, the dataset is loading or a replica waits for a primary, so a long start isn't killed as unhealthy.
