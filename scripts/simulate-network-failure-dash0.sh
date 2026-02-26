#!/bin/bash
# ============================================================
#  simulate-network-failure-dash0.sh
#
#  Blocks the OTel Collector from reaching Dash0's OTLP endpoint.
#  Unlike the Grafana variant (which blocks 3 specific ports to
#  in-cluster backends), this blocks all outbound TLS traffic from
#  the collector — simulating a full satellite link loss.
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Simulating Satellite Link Loss (Dash0 backend)...${NC}"
echo "=========================================="

EDGE_NODE="k3d-edge-observability-agent-0"

POD_IP=$(kubectl get pod -n observability -l app=otel-collector \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

if [ -z "$POD_IP" ]; then
  echo -e "${RED}OTel Collector pod not found. Is the demo running?${NC}"
  exit 1
fi

echo "$POD_IP" > /tmp/otel-collector-pod-ip

echo -e "\n${RED}Blocking OTel Collector (${POD_IP}) outbound to Dash0...${NC}"

# Block OTLP gRPC to Dash0 (port 4317 outbound to any external host)
# We block the FORWARD chain for destination port 4317 to non-cluster IPs.
# Also block 4318 (HTTP) in case of fallback.
docker exec "$EDGE_NODE" iptables -I FORWARD \
  -s "$POD_IP" -p tcp --dport 4317 ! -d 10.0.0.0/8 -j DROP

docker exec "$EDGE_NODE" iptables -I FORWARD \
  -s "$POD_IP" -p tcp --dport 4318 ! -d 10.0.0.0/8 -j DROP

# Also block DNS resolution for the Dash0 endpoint (port 443 for TLS)
docker exec "$EDGE_NODE" iptables -I FORWARD \
  -s "$POD_IP" -p tcp --dport 443 -j DROP

echo -e "\n${GREEN}Network failure simulated (NO pod restart — collector keeps running)${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}  Collector CANNOT reach Dash0${NC}"
echo -e "${RED}  All three signals queuing to disk${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}What is happening right now:${NC}"
echo "  - Application continues running normally"
echo "  - OTel Collector receives all telemetry from the app"
echo "  - Collector cannot export to Dash0 (outbound blocked)"
echo "  - Traces, metrics, AND logs all queue to disk"
echo "    (unlike Grafana setup, metrics also have file-backed queues)"
echo ""
echo -e "${YELLOW}To restore:${NC}"
echo "  ./scripts/restore-network-dash0.sh"
echo ""
