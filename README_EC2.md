# ClickHouse 4-Node Cluster Deployment on EC2

This guide explains how to deploy your 4-node ClickHouse cluster onto 4 separate EC2 instances using the provided Dockerfiles.

## Preparation
On each EC2 instance:
1. Install Docker.
2. Ensure Security Groups allow traffic on ports:
   - `9000` (Native protocol)
   - `8123` (HTTP protocol)
   - `9181` (ClickHouse Keeper - Node 1)
   - `9234` (Raft - Node 1)

## Step 1: Build the Images
You can build the images locally and push to a registry (like ECR/Docker Hub) or build directly on the EC2 instances.

### On Node 1 (EC2 Instance 1):
```bash
docker build -f Dockerfile.ch01 -t clickhouse-node1 .
```

### On Node 2 (EC2 Instance 2):
```bash
docker build -f Dockerfile.ch02 -t clickhouse-node2 .
```

### On Node 3 (EC2 Instance 3):
```bash
docker build -f Dockerfile.ch03 -t clickhouse-node3 .
```

### On Node 4 (EC2 Instance 4):
```bash
docker build -f Dockerfile.ch04 -t clickhouse-node4 .
```

## Step 2: Run the Containers
Since the configuration files use hostnames (`clickhouse01`, `clickhouse02`, etc.), you must map these hostnames to the **Private IPs** of your EC2 instances using the `--add-host` flag.

### Example:
Assume your EC2 Private IPs are:
- Node 1: `10.0.0.10`
- Node 2: `10.0.0.20`
- Node 3: `10.0.0.30`
- Node 4: `10.0.0.40`

**Run on EC2 Instance 1 (Node 1):**
```bash
docker run -d --name clickhouse \
  --restart always \
  -v clickhouse_data:/var/lib/clickhouse \
  --add-host clickhouse01:10.0.0.10 \
  --add-host clickhouse02:10.0.0.20 \
  --add-host clickhouse03:10.0.0.30 \
  --add-host clickhouse04:10.0.0.40 \
  -p 9000:9000 -p 8123:8123 -p 9181:9181 -p 9234:9234 \
  clickhouse-node1
```

**Run on EC2 Instance 2 (Node 2):**
```bash
docker run -d --name clickhouse \
  --restart always \
  -v clickhouse_data:/var/lib/clickhouse \
  --add-host clickhouse01:10.0.0.10 \
  --add-host clickhouse02:10.0.0.20 \
  --add-host clickhouse03:10.0.0.30 \
  --add-host clickhouse04:10.0.0.40 \
  -p 9000:9000 -p 8123:8123 \
  clickhouse-node2
```
*(Repeat for Node 3 and Node 4 using their respective images)*

## Important Notes
- **Keeper Persistence:** Ensure you use volumes (`-v clickhouse_data:/var/lib/clickhouse`) to persist your data and Keeper logs.
- **Networking:** All EC2 instances must be in the same VPC or have networking routes between them to allow communication on the ClickHouse ports.
