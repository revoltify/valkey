# valkeyctl

- [Introduction](#introduction)
- [Installation](#installation)
    - [Requirements](#requirements)
    - [Updating](#updating)
    - [Uninstalling](#uninstalling)
- [Preparing Your Servers](#preparing-your-servers)
- [Creating a Cluster](#creating-a-cluster)
    - [Single Server or High Availability](#single-server-or-high-availability)
    - [Read-Only Replicas](#read-only-replicas)
- [Connecting Laravel](#connecting-laravel)
    - [Using Your Own Domain](#using-your-own-domain)
    - [Without Client Certificates](#without-client-certificates)
    - [With Client Certificates](#with-client-certificates)
- [Managing Servers](#managing-servers)
    - [Adding Servers](#adding-servers)
    - [Removing Servers](#removing-servers)
    - [Replacing Servers](#replacing-servers)
- [Operations](#operations)
    - [Checking Status](#checking-status)
    - [Failing Over](#failing-over)
    - [Upgrading](#upgrading)
    - [Rotating Certificates](#rotating-certificates)
    - [Backups](#backups)
    - [Running Commands](#running-commands)
- [Command Reference](#command-reference)

<a name="introduction"></a>
## Introduction

`valkeyctl` sets up and runs a [Valkey](https://valkey.io) cluster on your own servers, entirely over SSH from your machine. One server or many, it handles installation, replication, automatic failover with Sentinel, TLS certificates and backups, so your Laravel application and Horizon workers always reach a single, encrypted endpoint.

Every server runs the same Docker image. Clients connect on port `6380` with TLS; each server forwards them to whichever server is currently the primary, so failovers are invisible to your application.

<a name="installation"></a>
## Installation

Install `valkeyctl` with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/revoltify/valkey/main/install.sh | sh
```

The command is installed to `/usr/local/bin` (or `~/.local/bin` when that isn't writable) and pinned to the version you installed. Everything `valkeyctl` knows about your clusters lives in `~/.valkeyctl`.

> [!WARNING]
> `~/.valkeyctl` holds each cluster's password, certificate authority key and client certificates. Back it up somewhere safe.

<a name="requirements"></a>
### Requirements

Your machine needs `bash`, `ssh`, `curl`, `openssl` and `awk`, which macOS and most Linux distributions already include. You also need SSH access as `root` (or a sudo user) to each server using your SSH key.

<a name="updating"></a>
### Updating

```bash
valkeyctl self-update
```

<a name="uninstalling"></a>
### Uninstalling

```bash
valkeyctl uninstall
```

Your cluster data in `~/.valkeyctl` is kept. To delete it as well, pass `--purge`. Your servers keep running either way.

```bash
valkeyctl uninstall --purge
```

<a name="preparing-your-servers"></a>
## Preparing Your Servers

Create your servers with your provider before running `valkeyctl`:

- Ubuntu 24.04+ or Debian 12+, with at least 2 GB of RAM.
- All servers in the **same region and private network** (VPC).
- Your SSH key installed for `root`.

In your provider's firewall, allow SSH from your own IP, all traffic inside the private network, and port `6380` from your application or load balancer. Nothing else needs to be open.

> [!NOTE]
> Placing a TCP load balancer in front of port `6380` on every server gives your application one stable address that never changes as you add or replace servers.

<a name="creating-a-cluster"></a>
## Creating a Cluster

Choose a name for your cluster and run `init`:

```bash
valkeyctl init main
```

The first time, `valkeyctl` asks a few questions: single server or high availability, each server's name, public IP and private IP, the SSH user, the addresses your application uses to connect (your load balancer IP or hostname), whether client certificates are required, and optional S3 backups. Press **Enter** to accept a default.

After showing you the plan, it installs Docker on every server, generates the password and TLS certificates, and starts the cluster.

<a name="single-server-or-high-availability"></a>
### Single Server or High Availability

A **single server** is the simplest start, but it has no failover: restarting it briefly interrupts your application.

**High availability** needs at least three servers. When the primary fails, the others elect a new one within about ten seconds, with no action from you. You can start with one server and [add more](#adding-servers) at any time; failover switches on automatically once the cluster reaches three.

| Servers | Survives |
|---|---|
| 1 | no failures |
| 2 | no failures (a live copy, but no automatic failover) |
| 3 | 1 failure |
| 5 | 2 failures |

<a name="read-only-replicas"></a>
### Read-Only Replicas

A read-only replica follows the primary like any other server and votes in Sentinel, but is never promoted. Mark it in its own `.env` with `VALKEY_CONFIG_REPLICA_PRIORITY=0` (it must not be `VALKEY_INITIAL_PRIMARY`), and list every read-only server's private IP on **all** servers:

```ini
READ_REPLICA_HOSTS=10.104.0.4,10.104.0.5
TLS_READ_PORT=6381
```

Each server's proxy then also accepts TLS on `TLS_READ_PORT` (default `6381`) and balances connections round-robin across the read-only replicas whose link to the primary is up. If none is available, reads fall back to the healthy standby replicas, and then to the primary. Port `6380` keeps routing to the primary. Open `6381` in your firewall the same way as `6380`.

<a name="connecting-laravel"></a>
## Connecting Laravel

The `env` command prints the settings for your application's `.env`:

```bash
valkeyctl env main
```

The connection is always encrypted. With your own domain, these settings are all your application needs. Without one, the servers use a private certificate and your application also needs its `ca.crt` file.

<a name="using-your-own-domain"></a>
### Using Your Own Domain

The simplest setup gives your servers a free, publicly trusted certificate from Let's Encrypt, so Laravel connects with plain `.env` settings and no certificate files.

You need a domain whose DNS is on Cloudflare and a Cloudflare API token with **Zone → DNS → Edit** for that zone only. Answer **y** to the domain question during `init`, or switch an existing cluster at any time:

```bash
valkeyctl domain main
```

Then point the domain at your load balancer, or at your servers' public IPs, with a DNS-only (grey cloud) record. `env` now prints:

```env
REDIS_CLIENT=phpredis
REDIS_SCHEME=tls
REDIS_HOST=valkey.example.com
REDIS_PORT=6380
REDIS_PASSWORD=...
```

Certificates renew automatically. Until the first one is issued, the servers keep using their private certificate.

> [!NOTE]
> Let's Encrypt proves you own the domain by creating a temporary DNS record, which is why the token is needed. No ports have to be opened for it.

<a name="without-client-certificates"></a>
### Without Client Certificates

Without a domain, and if you answered **No** to **Require client certificates**, `env` prints:

```env
REDIS_CLIENT=phpredis
REDIS_SCHEME=tls
REDIS_HOST=valkey.example.com
REDIS_PORT=6380
REDIS_PASSWORD=...
REDIS_TLS_CA_B64=...
```

Save the certificate as a file when your application starts. On Bunny Magic Containers, add this to your container's start command:

```bash
mkdir -p /tmp/valkey && echo "$REDIS_TLS_CA_B64" | base64 -d > /tmp/valkey/ca.crt
```

Then add a `context` to your Redis connection in `config/database.php`:

```php
'default' => [
    'scheme' => env('REDIS_SCHEME', 'tcp'),
    'host' => env('REDIS_HOST', '127.0.0.1'),
    'port' => env('REDIS_PORT', '6379'),
    'password' => env('REDIS_PASSWORD'),
    'database' => env('REDIS_DB', '0'),
    'context' => [
        'stream' => [
            'cafile' => '/tmp/valkey/ca.crt',
        ],
    ],
],
```

<a name="with-client-certificates"></a>
### With Client Certificates

If you answered **Yes**, your application also proves its identity with a client certificate, so `env` adds two more lines:

```env
REDIS_TLS_CERT_B64=...
REDIS_TLS_KEY_B64=...
```

Write all three files when your application starts:

```bash
mkdir -p /tmp/valkey \
  && echo "$REDIS_TLS_CA_B64" | base64 -d > /tmp/valkey/ca.crt \
  && echo "$REDIS_TLS_CERT_B64" | base64 -d > /tmp/valkey/client.crt \
  && echo "$REDIS_TLS_KEY_B64" | base64 -d > /tmp/valkey/client.key
```

And reference them in the `context`:

```php
'context' => [
    'stream' => [
        'cafile' => '/tmp/valkey/ca.crt',
        'local_cert' => '/tmp/valkey/client.crt',
        'local_pk' => '/tmp/valkey/client.key',
    ],
],
```

> [!NOTE]
> On a regular server, skip the decoding: `valkeyctl certs main` copies the files to your current directory. Upload them to your server and use their paths in the `context`.

> [!NOTE]
> When several applications share one cluster, give each its own `REDIS_DB`, `REDIS_CACHE_DB`, `REDIS_PREFIX` and `HORIZON_PREFIX`. `php artisan cache:clear` empties the whole cache database, so applications should never share a database number.

<a name="managing-servers"></a>
## Managing Servers

<a name="adding-servers"></a>
### Adding Servers

Create the server in the same private network, then pass its name and `public-ip/private-ip`:

```bash
valkeyctl add-node main valkey-04 203.0.113.14/10.104.0.7
```

The server is installed, joins as a replica and starts receiving traffic. The rest of the cluster is updated automatically.

<a name="removing-servers"></a>
### Removing Servers

```bash
valkeyctl remove-node main valkey-04
```

`valkeyctl` refuses to remove the current primary or to leave fewer than three servers. The removed server's data stays on disk until you delete the server.

<a name="replacing-servers"></a>
### Replacing Servers

Swap a server for a new one without dropping below your current size:

```bash
valkeyctl replace-node main valkey-02 valkey-05 203.0.113.15/10.104.0.8
```

<a name="operations"></a>
## Operations

<a name="checking-status"></a>
### Checking Status

```bash
valkeyctl status main
```

Shows each server's role, replication link and lag, memory, containers and TLS check, plus what every Sentinel believes, ending with `healthy` or the problems found.

<a name="failing-over"></a>
### Failing Over

Move the primary role to another server, for example before maintenance:

```bash
valkeyctl failover main
```

To see how your application behaves during a real failure, `test-failover` stops the primary under write load and reports the error window and any lost writes:

```bash
valkeyctl test-failover main
```

<a name="upgrading"></a>
### Upgrading

```bash
valkeyctl upgrade main
```

Replicas are upgraded one at a time, then the primary role moves away and the old primary is upgraded last. Your application sees one short failover. Pass a tag to pin a specific image version: `valkeyctl upgrade main 1.2.0`.

<a name="rotating-certificates"></a>
### Rotating Certificates

```bash
valkeyctl rotate-certs main
```

Issues a new server certificate. Add `--client` to also issue a new client certificate, then update your application with `valkeyctl env main`.

<a name="backups"></a>
### Backups

When backups are enabled during `init`, the current primary uploads a compressed snapshot to your S3-compatible storage (Bunny Storage, Cloudflare R2, AWS S3, Backblaze B2) on a schedule. To take one immediately:

```bash
valkeyctl backup-now main
```

If a server starts with no data, it restores the newest valid backup automatically.

<a name="running-commands"></a>
### Running Commands

Run any `valkey-cli` command on the current primary:

```bash
valkeyctl cli main INFO memory
```

Or open a shell on a server:

```bash
valkeyctl ssh main valkey-01
```

<a name="command-reference"></a>
## Command Reference

| Command | Description |
|---|---|
| `init <cluster>` | Create a cluster, asking for its settings the first time |
| `status <cluster>` | Health of every server and Sentinel |
| `add-node <cluster> <name> <public>/<private>` | Add a server |
| `remove-node <cluster> <name>` | Remove a server |
| `replace-node <cluster> <old> <new> <public>/<private>` | Replace a server |
| `failover <cluster>` | Move the primary role to another server |
| `test-failover <cluster>` | Measure a failover under write load |
| `upgrade <cluster> [tag]` | Rolling upgrade to a new image |
| `rotate-certs <cluster> [--client]` | Issue new certificates |
| `domain <cluster>` | Use a Let's Encrypt certificate for your domain |
| `backup-now <cluster>` | Upload a backup now |
| `env <cluster>` | Print Laravel environment variables |
| `certs <cluster> [dir]` | Copy the client certificates |
| `cli <cluster> <command>...` | Run `valkey-cli` on the primary |
| `ssh <cluster> [node]` | Open a shell on a server |
| `list` | List your clusters |
| `version` | Show the installed version |
| `self-update` | Install the latest version |
| `uninstall [--purge]` | Remove `valkeyctl` |

Every command that changes your servers shows its plan and asks for confirmation first. Pass `--yes` to skip the prompt, for example in scripts.
