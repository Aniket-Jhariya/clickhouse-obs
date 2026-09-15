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

## Deployment (two different styles - do not mix them up)

**Node 1** runs the **stock upstream image** with every config file bind-mounted
from this repo. Nothing is baked in; editing a file here changes node 1 directly.

**Nodes 2-4** run **locally built images** (`clickhouse-node2/3/4`) with config
copied in at build time by `Dockerfile.chNN`. Editing a file here has no effect
on them until the image is rebuilt AND the container recreated.

### Node 1 (172.31.8.251) - stock image + bind mounts

```bash
docker run -d \
  --name clickhouse01 \
  --hostname clickhouse01 \
  --restart unless-stopped \
  --add-host clickhouse01:172.31.8.251 \
  --add-host clickhouse02:172.31.2.13 \
  --add-host clickhouse03:172.31.4.5 \
  --add-host clickhouse04:172.31.14.89 \
  -e TZ=UTC \
  -e CLICKHOUSE_CONFIG=/etc/clickhouse-server/config.xml \
  -v clickhouse_data:/var/lib/clickhouse \
  -v /home/ubuntu/clickhouse-obs/clickhouse01/users.xml:/etc/clickhouse-server/users.xml \
  -v /home/ubuntu/clickhouse-obs/clickhouse01/config.d/macros.xml:/etc/clickhouse-server/config.d/macros.xml \
  -v /home/ubuntu/clickhouse-obs/clickhouse01/config.d/network.xml:/etc/clickhouse-server/config.d/network.xml \
  -v /home/ubuntu/clickhouse-obs/clickhouse01/config.d/storage_policy.xml:/etc/clickhouse-server/config.d/storage_policy.xml \
  -v /home/ubuntu/clickhouse-obs/clickhouse01/config.d/zookeeper.xml:/etc/clickhouse-server/config.d/zookeeper.xml \
  -v /home/ubuntu/clickhouse-obs/clickhouse01/config.d/interserver.xml:/etc/clickhouse-server/config.d/interserver.xml \
  -v /home/ubuntu/clickhouse-obs/clickhouse01/config.d/keeper_config.xml:/etc/clickhouse-server/config.d/keeper_config.xml \
  -p 8123:8123 -p 9000:9000 -p 9009:9009 -p 9181:9181 \
  clickhouse/clickhouse-server:latest
```

`clickhouse_data` is an external named volume - it MUST already exist, and it
carries all table data. Never pass `-v` to `docker rm`.

### Nodes 2-4 - build then run

```bash
# N = 2, 3 or 4
cd /home/ubuntu/clickhouse-obs
cp clickhouse0N/config.d/storage_policy.xml.template clickhouse0N/config.d/storage_policy.xml
docker build -f Dockerfile.chN -t clickhouse-nodeN .

docker run -d \
  --name clickhouse \
  --hostname clickhouse0N \
  --restart unless-stopped \
  --add-host clickhouse01:172.31.8.251 \
  --add-host clickhouse02:172.31.2.13 \
  --add-host clickhouse03:172.31.4.5 \
  --add-host clickhouse04:172.31.14.89 \
  -e S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" \
  -e S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" \
  -v clickhouse_data:/var/lib/clickhouse \
  -p 8123:8123 -p 9000:9000 -p 9009:9009 \
  clickhouse-nodeN
```

> **The images currently on nodes 2-4 are stale.** They were built before the
> external Keeper ensemble and the S3 storage policy existed, so they still
> contain a `zookeeper.xml` pointing at `clickhouse01:9181` and no
> `storage_policy.xml`. Recreating one of those containers from its existing
> image would attach it to the wrong Keeper and leave every table that uses
> `hot_to_cold_policy` unable to load. Rebuild from this repo first.

`--hostname` is mandatory on every node - see the Distributed DDL section above.

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
  ensemble). It is retained deliberately: node 1 bind-mounts it, and dropping it
  would change which ports node 1 binds. Safe to remove in a separate change.
- `memory_tweak.xml` is present on nodes 2-4 but not node 1.
