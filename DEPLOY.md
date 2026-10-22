# Deploy guide: Valkey HA on 3+ DigitalOcean droplets behind a load balancer

Result: a Sentinel group of N droplets on a private VPC, reachable from outside (e.g. Bunny Magic Containers) only through a DigitalOcean load balancer on TLS port `6380`. The droplets themselves expose nothing to the internet except SSH from your IP.

```
App ──TLS :6380──► DO Network Load Balancer (only public endpoint)
                         │ private VPC
          ┌──────────────┼──────────────┐
      valkey-01       valkey-02       valkey-03 ...
      proxy :6380 → current primary (any node forwards to it)
      valkey :6379, sentinel :26379, probe :8080 (VPC only)
```

Use an odd number of nodes (3, 5, …). Sentinel needs a majority to fail over: 3 nodes survive 1 failure, 5 survive 2.

## 1. Create the droplets

- N droplets, **same region and same VPC**, Ubuntu 24.04+ or Debian 12, at least 2 GB RAM.
- Add your SSH key and the tag `valkey` to each.
- Write down each droplet's **private VPC IP** (`ip -4 addr show eth1`). The examples below use:

| Node | Private IP |
|---|---|
| valkey-01 | 10.104.0.5 |
| valkey-02 | 10.104.0.6 |
| valkey-03 | 10.104.0.2 |

## 2. Cloud Firewall (DO panel → Networking → Firewalls)

Apply to tag `valkey`:

| Direction | Type | Port | Source |
|---|---|---|---|
| Inbound | SSH | 22 | your IP only |
| Inbound | All TCP | all | VPC CIDR, e.g. `10.104.0.0/20` |
| Inbound | Custom TCP | 6380 | the load balancer (pick it as source once it exists) |
| Outbound | All | all | anywhere |

Nothing else is open. Do not run `host/firewall` (ufw) when you use the DO firewall; if ufw is already active, `ufw disable` it so only one firewall decides.

## 3. Prepare every droplet (as root)

```bash
apt-get update && apt-get install -y docker.io docker-compose-v2 docker-buildx git
```

```bash
git clone https://github.com/revoltify/valkey /srv/valkey
```

```bash
sh /srv/valkey/host/setup
```

`host/setup` sets `vm.overcommit_memory=1`, `somaxconn` and disables transparent huge pages. It should print `overcommit_memory=1 thp=always madvise [never]`.

Get the image, either:

- **From GHCR** (after this branch is merged to `main`, CI publishes it). If the package is private, `docker login ghcr.io` first.

```bash
docker pull ghcr.io/revoltify/valkey:latest
```

- **Or build it on the droplet:**

```bash
docker build -t ghcr.io/revoltify/valkey:latest /srv/valkey
```

## 4. Create the load balancer

DO panel → Networking → Load Balancers → **Network Load Balancer**, same region and VPC:

- Forwarding rule: **TCP 6380 → TCP 6380**
- Targets: tag `valkey`
- Health check: **TCP**, port `6380`, interval 3 s, unhealthy 2, healthy 2
- Optional allow rules: only the IPs your app connects from (for Bunny: `https://api.bunny.net/mc/nodes/plain`)

Every node's proxy forwards to the current primary, so all healthy nodes can receive traffic. Note the **load balancer IP**, and if you want a hostname, add a DNS-only (grey cloud) A record such as `valkey.example.com` pointing to it.

Now finish the firewall rule from step 2 (port 6380 from the load balancer).

## 5. Certificates (once, on valkey-01)

Put every name clients use in the certificate: the load balancer IP, the hostname, and the private IPs (for apps inside the VPC):

```bash
cd /srv/valkey && mkdir -p tls && docker run --rm -v ./tls:/certs --entrypoint generate-certs ghcr.io/revoltify/valkey:latest valkey.example.com 203.0.113.50 10.104.0.5 10.104.0.6 10.104.0.2
```

Copy `tls/ca.crt` and `tls/server.pem` to `/srv/valkey/tls/` on every other node, then on each node:

```bash
chown 999 /srv/valkey/tls/server.pem /srv/valkey/tls/ca.crt && chmod 600 /srv/valkey/tls/server.pem
```

Download `ca.crt`, `client.crt` and `client.key` for your apps. Move `ca.key` off the server to a safe place; it's only needed to issue new certificates.

## 6. `.env` on every node

Generate the password once and use the same value everywhere:

```bash
openssl rand -hex 32
```

`/srv/valkey/.env` (mode 600):

```env
VALKEY_PASSWORD=<the generated password>
VALKEY_PRIVATE_IP=10.104.0.5
SENTINEL_HOSTS=10.104.0.5,10.104.0.6,10.104.0.2
VALKEY_INITIAL_PRIMARY=true
SENTINEL_QUORUM=2
TLS_CLIENT_VERIFY=required
BACKUP_ENABLED=false
```

Per node, change only:

- `VALKEY_PRIVATE_IP`: that node's private IP.
- `VALKEY_INITIAL_PRIMARY`: `true` on valkey-01 only, `false` everywhere else.

Keep `SENTINEL_HOSTS` identical on all nodes, with valkey-01 first. Set `SENTINEL_QUORUM` to a majority: 2 for 3 nodes, 3 for 5 nodes.

To enable S3 backups, set `BACKUP_ENABLED=true` and the `S3_*` variables from the README. Only the current primary uploads.

## 7. Start the group

On valkey-01 first, then wait ~10 s and start the others:

```bash
cd /srv/valkey && docker compose --profile ha up -d
```

Check on any node:

```bash
cd /srv/valkey && docker compose --profile ha ps
```

```bash
docker exec valkey-valkey-1 sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli INFO replication' | grep -E 'role|connected_slaves|master_link_status'
```

```bash
docker exec valkey-sentinel-1 sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli -p 26379 SENTINEL master main' | paste - - | grep -E '^(ip|num-slaves|num-other-sentinels|quorum)\s'
```

Expected: valkey-01 `role:master` with `connected_slaves:2`, the others `role:slave` with `master_link_status:up`, and Sentinel `num-slaves 2`, `num-other-sentinels 2`.

## 8. Test from outside

From a machine with the client files and `valkey-cli`:

```bash
VALKEYCLI_AUTH=<password> valkey-cli --tls --cacert ca.crt --cert client.crt --key client.key -h <load balancer IP or hostname> -p 6380 INFO replication
```

It should answer `role:master`. Without `--cert/--key` the connection must be refused. Ports `6379`, `8080` and `26379` on the droplets' public IPs must not answer.

Failover drill (run a client loop while doing it):

```bash
docker exec valkey-sentinel-1 sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli -p 26379 SENTINEL FAILOVER main'
```

Expect a few seconds of errors, then writes continue on the new primary. Stopping a primary's container or powering off its droplet gives about 7 s of errors (5 s detection plus election).

## 9. Laravel

```env
REDIS_CLIENT=phpredis
REDIS_SCHEME=tls
REDIS_HOST=valkey.example.com
REDIS_PORT=6380
REDIS_PASSWORD=<password>
REDIS_TLS_CA=/tmp/valkey/ca.crt
REDIS_TLS_CERT=/tmp/valkey/client.crt
REDIS_TLS_KEY=/tmp/valkey/client.key
```

Use the `context.stream` block from the README in `config/database.php`. On Bunny Magic Containers, store the three files as base64 env vars and write them at container start:

```bash
mkdir -p /tmp/valkey && printf '%s' "$REDIS_TLS_CA_B64" | base64 -d > /tmp/valkey/ca.crt && printf '%s' "$REDIS_TLS_CERT_B64" | base64 -d > /tmp/valkey/client.crt && printf '%s' "$REDIS_TLS_KEY_B64" | base64 -d > /tmp/valkey/client.key && chmod 600 /tmp/valkey/client.key
```

Several apps can share the group: give each app its own `REDIS_DB`/`REDIS_CACHE_DB` numbers, `REDIS_PREFIX` and `HORIZON_PREFIX`. `php artisan cache:clear` flushes the whole cache database, so never share a database number between apps.

## Day-2 operations

**Add a node:** create a droplet (tag `valkey`, same VPC), do steps 3 and 5 (copy `ca.crt` and `server.pem`), write its `.env` with `VALKEY_INITIAL_PRIMARY=false`, start it. It joins as a replica and the load balancer picks it up through the tag. Then raise the quorum to the new majority on every Sentinel:

```bash
docker exec valkey-sentinel-1 sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli -p 26379 SENTINEL SET main quorum 3'
```

**Remove a node:** `docker compose --profile ha down` on it, delete the droplet, then on every remaining Sentinel:

```bash
docker exec valkey-sentinel-1 sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli -p 26379 SENTINEL RESET main'
```

**Update the image (rolling, no downtime beyond one failover):**

1. On each replica, one at a time: `git -C /srv/valkey pull`, pull or rebuild the image, `docker compose --profile ha up -d`, wait until `master_link_status:up`.
2. Move the primary role away: `SENTINEL FAILOVER main`.
3. Update the old primary the same way.

**Resize:** same order as an update: resize replicas one at a time, fail over, resize the old primary.

**Rotate certificates:** delete `tls/server.*` (or `tls/client.*`) on valkey-01, rerun `generate-certs` with the same names, copy `server.pem` to every node, and restart the proxies with `docker compose restart proxy`. The CA stays the same, so clients keep working until their own certificate is replaced.

## Redeploying from scratch

This deletes all data on the node:

```bash
cd /srv/valkey && docker compose --profile ha down && rm -rf data sentinel
```

Do it on every node, then follow steps 5–7 again. The `sentinel` folder holds what Sentinel learned (current primary, peers); it must be wiped together with `data`, or a node may rejoin the old group.
