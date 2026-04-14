#!/bin/bash

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <node_name>"
    echo "Example: $0 clickhouse01"
    exit 1
fi

NODE_NAME=$1
CONFIG_DIR="/etc/clickhouse-server"

echo "Deploying configuration for $NODE_NAME..."

# Copy users.xml
sudo cp "$NODE_NAME/users.xml" "$CONFIG_DIR/users.xml"

# Copy config.d files
sudo cp "$NODE_NAME/config.d/"* "$CONFIG_DIR/config.d/"

echo "Configuration for $NODE_NAME deployed successfully."
echo "Remember to replace <EC2_PRIVATE_IP_1> in your zookeeper.xml and keeper_config.xml with the actual private IP of your first EC2 instance."
