#!/usr/bin/env bash

set -euo pipefail

echo "Updating apt package index..."
sudo apt-get update

echo "Installing required HTTPS + GPG dependencies..."
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    dirmngr \
    gnupg

echo "Adding ClickHouse GPG key..."
sudo apt-key adv \
    --keyserver hkp://keyserver.ubuntu.com:80 \
    --recv 8919F6BD2B48D754

echo "Adding ClickHouse repository..."
echo "deb https://packages.clickhouse.com/deb stable main" | \
    sudo tee /etc/apt/sources.list.d/clickhouse.list > /dev/null

echo "Refreshing apt sources..."
sudo apt-get update

echo "Installing ClickHouse server and client..."
sudo apt-get install -y \
    clickhouse-server \
    clickhouse-client

echo "ClickHouse installation complete."
