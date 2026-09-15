# ClickHouse 4-Node Cluster on EC2

2 shards x 2 replicas, cross-replicated, backed by an **external 3-node Keeper ensemble**.

| Node | EC2 IP | Container hostname | Shard | Replica |
|------|--------|--------------------|-------|---------|
| 1 | 172.31.8.251 | `clickhouse01` | 1 | clickhouse01 |
| 2 | 172.31.2.13 | `clickhouse02` | 2 | clickhouse02 |
| 3 | 172.31.4.5 | `clickhouse03` | 1 | clickhouse03 |
| 4 | 172.31.14.89 | `clickhouse04` | 2 | clickhouse04 |

Keeper ensemble (separate hosts, **not** the ClickHouse nodes):
`172.31.8.27:9181`, `172.31.3.8:9181`, `172.31.5.84:9181`

---

## CRITICAL: why the cluster must use hostnames, not IPs

`remote_servers` **must** list `clickhouse01`..`clickhouse04`, never the EC2 IPs.

ClickHouse decides whether a host in a Distributed DDL task is *itself* by resolving
the entry and comparing it against **its own network interfaces**. Under Docker
bridge networking a container's interfaces are only `127.0.0.1` and `172.17.0.2` -
never the EC2 IP. With IPs in `remote_servers`, every node declines every task:

```
DDLWorker: Will not execute task query-XXXX: There is no a local address in host list
```

`ON CLUSTER` then hangs for `distributed_ddl_task_timeout` (180s) and throws
"is not finished on 4 of 4 hosts", while ordinary replication keeps working -
which makes it look like a connectivity problem when it is not.

With hostnames it resolves correctly: Docker auto-adds `172.17.0.2 <container-hostname>`
to `/etc/hosts`, so each node matches exactly itself and no one else.

**This is why every container MUST be started with `--hostname clickhouseNN`.**
A container whose hostname is left as the random container ID cannot identify
itself and will silently drop out of all `ON CLUSTER` DDL.

`interserver_http_host` does **not** affect this - it governs the 9009 part-fetch
URL only. The two mechanisms are independent.

---

## Prepare credentials (required before building)

`storage_policy.xml` is gitignored because it holds live S3 keys. On each node:

```bash
cd clickhouseNN/config.d
cp storage_policy.xml.template storage_policy.xml
```

The template reads credentials from the environment, so pass them at run time
(see `-e` flags below). Never commit a copy containing literal keys.

## Build

```bash
# on node N
docker build -f Dockerfile.chNN -t clickhouse-nodeN .
```

## Run

Note `--hostname`, the four `--add-host` entries, and the S3 env vars.

```bash
# ---- Node 1 (172.31.8.251) ----
docker run -d --name clickhouse01 \
  --restart always \
  --hostname clickhouse01 \
  -v clickhouse_data:/var/lib/clickhouse \
  --add-host clickhouse01:172.31.8.251 \
  --add-host clickhouse02:172.31.2.13 \
  --add-host clickhouse03:172.31.4.5 \
  --add-host clickhouse04:172.31.14.89 \
  -e S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" \
  -e S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" \
  -p 9000:9000 -p 8123:8123 -p 9009:9009 \
  clickhouse-node1
```

Repeat for nodes 2-4, changing `--name`, `--hostname`, and the image tag.
The `--add-host` block is identical on every node; `--hostname` makes Docker add
the self-mapping that Distributed DDL depends on.

## Verify after any rebuild or recreate

```sql
-- 1. cluster must show hostnames, not IPs
SELECT host_name FROM system.clusters WHERE cluster='cross_replicated_cluster';

-- 2. all four must register for DDL
SELECT name FROM system.zookeeper WHERE path='/clickhouse/task_queue/replicas';

-- 3. ON CLUSTER must complete in ~1s, not hang for 180s
CREATE DATABASE ddl_smoke_test ON CLUSTER cross_replicated_cluster;
DROP DATABASE ddl_smoke_test ON CLUSTER cross_replicated_cluster;

-- 4. Keeper must be the external ensemble, not a local one
SELECT host, port FROM system.zookeeper_connection;
```

If step 3 hangs, check `docker logs` for "There is no a local address in host list".

---

## Replicated database (otel_replicated)

```sql
CREATE DATABASE otel_replicated ON CLUSTER cross_replicated_cluster
ENGINE = Replicated('/clickhouse/databases/otel_replicated_v1', '{shard}', '{replica}');
```

The engine takes **three** arguments - `zoo_path`, `shard_name`, `replica_name`.
A two-argument form with `{shard}` baked into the path is rejected
("Replicated database requires 3 arguments").

Tables inside a Replicated database are created **without** `ON CLUSTER` - the
database engine propagates DDL itself - and **without** explicit
ReplicatedMergeTree path arguments, which it assigns as
`/clickhouse/tables/{uuid}/{shard}`.

## Notes

- `clickhouse01/config.d/keeper_config.xml` configures an embedded single-node
  Keeper on node 1 that **nothing uses** (all nodes talk to the external
  ensemble). It is retained only because node 1 bind-mounts it. Safe to drop
  when node 1 is next rebuilt.
- `memory_tweak.xml` is present on nodes 2-4 but not node 1.
