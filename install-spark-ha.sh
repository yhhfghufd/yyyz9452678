#!/usr/bin/env bash
set -euo pipefail

# One-command installer for real Linux hosts.
# Usage on every node:
#   curl -fsSL <your-url>/install-spark-ha.sh | sudo bash
# or:
#   sudo IMAGE=yyyz9452678/spark-ha-all:3.5.6 bash install-spark-ha.sh
# Optional only when automatic IP detection is wrong:
#   sudo AGENT_NODE_IP=192.168.0.101 bash install-spark-ha.sh

IMAGE=${IMAGE:-yyyz9452678/spark-ha-all:3.5.6}
AGENT_CONTAINER=${AGENT_CONTAINER:-spark-agent}
RUNTIME_DIR=${RUNTIME_DIR:-/opt/spark-ha-node}
NODE_NAME=${NODE_NAME:-$(hostname)}
HTTP_PORT=${HTTP_PORT:-19090}
WEB_PORT=${WEB_PORT:-19100}
DISCOVERY_GROUP=${DISCOVERY_GROUP:-239.255.77.77}
DISCOVERY_PORT=${DISCOVERY_PORT:-19091}

echo "[0/6] Spark HA one-image installer"
echo "IMAGE=$IMAGE"
echo "NODE_NAME=$NODE_NAME"
echo "RUNTIME_DIR=$RUNTIME_DIR"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Please run with sudo/root, e.g. sudo bash install-spark-ha.sh"
  exit 1
fi

echo "[1/6] Installing/starting Docker..."
if ! command -v docker >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y docker.io
  elif command -v yum >/dev/null 2>&1; then
    yum install -y docker
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y docker
  else
    echo "ERROR: Cannot install Docker automatically on this OS. Install Docker first, then rerun this script."
    exit 1
  fi
fi
systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true

echo "[2/6] Preparing runtime directory..."
mkdir -p "$RUNTIME_DIR/runtime/generated" "$RUNTIME_DIR/apps" "$RUNTIME_DIR/cluster" "$RUNTIME_DIR/conf"
chmod -R 755 "$RUNTIME_DIR"

echo "[3/6] Opening firewall ports when ufw exists..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow 19090/tcp >/dev/null 2>&1 || true
  ufw allow 19100/tcp >/dev/null 2>&1 || true
  ufw allow 19091/udp >/dev/null 2>&1 || true
  ufw allow 2181/tcp >/dev/null 2>&1 || true
  ufw allow 2888/tcp >/dev/null 2>&1 || true
  ufw allow 3888/tcp >/dev/null 2>&1 || true
  ufw allow 8020/tcp >/dev/null 2>&1 || true
  ufw allow 9870/tcp >/dev/null 2>&1 || true
  ufw allow 8485/tcp >/dev/null 2>&1 || true
  ufw allow 7077/tcp >/dev/null 2>&1 || true
  ufw allow 8081/tcp >/dev/null 2>&1 || true
  ufw allow 8082/tcp >/dev/null 2>&1 || true
fi

echo "[4/6] Pulling image..."
docker pull "$IMAGE"

echo "[5/6] Starting Agent container..."
docker rm -f "$AGENT_CONTAINER" >/dev/null 2>&1 || true
DOCKER_ENV_IP=()
if [ -n "${AGENT_NODE_IP:-}" ]; then
  DOCKER_ENV_IP=(-e AGENT_NODE_IP="$AGENT_NODE_IP" -e AGENT_ADVERTISE_IP="$AGENT_NODE_IP")
else
  DOCKER_ENV_IP=(-e AGENT_NODE_IP=auto -e AGENT_ADVERTISE_IP=auto)
fi

docker run -d \
  --name "$AGENT_CONTAINER" \
  --restart unless-stopped \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$RUNTIME_DIR":/opt/runtime \
  -e AGENT_NODE_NAME="$NODE_NAME" \
  "${DOCKER_ENV_IP[@]}" \
  -e PACKAGE_ON_HOST="$RUNTIME_DIR" \
  -e PACKAGE_IN_AGENT=/opt/runtime \
  -e PACKAGE_DEFAULTS_IN_AGENT=/opt/package-default \
  -e GENERATED_CONFIG_ROOT=/opt/runtime/runtime/generated \
  -e IMAGE_FULL_NAME="$IMAGE" \
  -e AGENT_HTTP_PORT="$HTTP_PORT" \
  -e AGENT_WEB_PORT="$WEB_PORT" \
  -e DISCOVERY_GROUP="$DISCOVERY_GROUP" \
  -e DISCOVERY_PORT="$DISCOVERY_PORT" \
  -e NODE_OFFLINE_TIMEOUT=45 \
  "$IMAGE" all

# Create a tiny local command for later upgrade/restart. It re-runs this same container logic.
cat >/usr/local/bin/spark-ha-agent-reinstall <<EOF
#!/usr/bin/env bash
set -euo pipefail
IMAGE="$IMAGE" AGENT_CONTAINER="$AGENT_CONTAINER" RUNTIME_DIR="$RUNTIME_DIR" NODE_NAME="\$(hostname)" bash /opt/spark-ha-node/install-spark-ha.sh
EOF
chmod +x /usr/local/bin/spark-ha-agent-reinstall || true
cp "$0" "$RUNTIME_DIR/install-spark-ha.sh" 2>/dev/null || true

DISPLAY_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}' || true)
if [ -z "$DISPLAY_IP" ]; then DISPLAY_IP=$(hostname -I 2>/dev/null | awk '{print $1}'); fi
if [ -z "$DISPLAY_IP" ]; then DISPLAY_IP="<this-node-ip>"; fi

echo "[6/6] Done."
echo "Web UI: http://$DISPLAY_IP:$WEB_PORT"
echo "API:    http://$DISPLAY_IP:$HTTP_PORT/health"
echo "The Agent uses dynamic IP detection in host-network mode; DHCP changes are rediscovered by P2P heartbeats."
