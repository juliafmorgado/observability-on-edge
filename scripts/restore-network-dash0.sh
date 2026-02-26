#!/bin/bash
# ============================================================
#  restore-network-dash0.sh
#
#  Removes the iptables DROP rules added by
#  simulate-network-failure-dash0.sh.
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}Restoring Satellite Link (Dash0 backend)...${NC}"
echo "=========================================="

EDGE_NODE="k3d-edge-observability-agent-0"

if [ ! -f /tmp/otel-collector-pod-ip ]; then
  echo -e "${RED}Pod IP file not found. Run simulate-network-failure-dash0.sh first.${NC}"
  exit 1
fi

POD_IP=$(cat /tmp/otel-collector-pod-ip)

echo -e "\n${GREEN}Removing iptables DROP rules for OTel Collector (${POD_IP})...${NC}"

docker exec "$EDGE_NODE" iptables -D FORWARD \
  -s "$POD_IP" -p tcp --dport 4317 ! -d 10.0.0.0/8 -j DROP 2>/dev/null || true

docker exec "$EDGE_NODE" iptables -D FORWARD \
  -s "$POD_IP" -p tcp --dport 4318 ! -d 10.0.0.0/8 -j DROP 2>/dev/null || true

docker exec "$EDGE_NODE" iptables -D FORWARD \
  -s "$POD_IP" -p tcp --dport 443 -j DROP 2>/dev/null || true

rm -f /tmp/otel-collector-pod-ip

echo -e "\n${GREEN}Link restored — OTel Collector can reach Dash0 again${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  File-backed queues draining to Dash0 now${NC}"
echo -e "${GREEN}  ALL three signals backfill (including metrics)${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}What is happening right now:${NC}"
echo "  - OTel Collector detects Dash0 is reachable again"
echo "  - File-backed queues draining: traces, metrics, AND logs"
echo "  - All signals arrive with original timestamps"
echo "  - Check your Dash0 dashboards for the backfilled data"
echo ""
