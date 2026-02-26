#!/bin/bash
# ============================================================
#  setup-dash0.sh — Dash0 backend variant
#
#  Same edge pipeline (app + OTel Collector + Fluent Bit) but
#  exports to Dash0 instead of local Jaeger/Prometheus/Loki/Grafana.
#
#  Before running:
#    1. Edit k8s/edge-node/dash0-secret.yaml with your Dash0
#       auth token and OTLP endpoint.
#    2. Run this script.
#
#  Key difference from the Grafana setup:
#    - No hub-node backends (Jaeger, Prometheus, Loki, Grafana)
#    - Single OTLP exporter to Dash0 for all three signals
#    - File-backed persistent queues for traces, metrics, AND logs
#      (metrics gap-fill works because Dash0 accepts out-of-order data)
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Edge Observability Demo - Dash0 Backend Setup${NC}"
echo "=========================================="

# Check prerequisites
echo -e "\n${YELLOW}Checking prerequisites...${NC}"

command -v docker >/dev/null 2>&1 || { echo -e "${RED}docker is required but not installed.${NC}" >&2; exit 1; }
command -v k3d >/dev/null 2>&1 || { echo -e "${RED}k3d is required but not installed.${NC}" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl is required but not installed.${NC}" >&2; exit 1; }

echo -e "${GREEN}All prerequisites installed${NC}"

# Validate Dash0 secret has been configured
if grep -q "REPLACE_ME" k8s/edge-node/dash0-secret.yaml; then
  echo -e "${RED}Edit k8s/edge-node/dash0-secret.yaml with your Dash0 credentials first.${NC}"
  echo "  1. Set auth-token to your Dash0 Bearer token"
  echo "  2. Set endpoint to your Dash0 OTLP endpoint (e.g. ingress.eu-west-1.aws.dash0.com:4317)"
  exit 1
fi

# Build application Docker image
echo -e "\n${YELLOW}Building application Docker image...${NC}"
cd app
docker build -t edge-demo-app:latest .
cd ..
echo -e "${GREEN}Application image built${NC}"

# Create k3d cluster with 2 nodes
echo -e "\n${YELLOW}Creating k3d cluster with 2 nodes...${NC}"
k3d cluster delete edge-observability 2>/dev/null || true

k3d cluster create edge-observability \
  --agents 2 \
  --wait

echo -e "${GREEN}Cluster created${NC}"

# Wait for cluster to be ready
echo -e "\n${YELLOW}Waiting for cluster to be ready...${NC}"
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# Label nodes
echo -e "\n${YELLOW}Labeling nodes...${NC}"
NODES=($(kubectl get nodes -o name | grep agent))

if [ ${#NODES[@]} -lt 2 ]; then
  echo -e "${RED}Expected 2 agent nodes, found ${#NODES[@]}${NC}"
  exit 1
fi

kubectl label ${NODES[0]} node-role=edge --overwrite
kubectl label ${NODES[1]} node-role=hub --overwrite

echo -e "${GREEN}Nodes labeled${NC}"
echo "  - ${NODES[0]} = edge"
echo "  - ${NODES[1]} = hub"

# Import application image to k3d
echo -e "\n${YELLOW}Importing application image to k3d...${NC}"
k3d image import edge-demo-app:latest -c edge-observability
echo -e "${GREEN}Image imported${NC}"

# Pre-pull OTel Collector image
echo -e "\n${YELLOW}Pre-pulling OTel Collector image...${NC}"
ARCH=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
docker pull --platform "linux/${ARCH}" ghcr.io/graz-dev/otel-collector-edge:0.1.0 2>&1 | tail -1
echo -e "${GREEN}OTel Collector image cached${NC}"

# Create namespace
echo -e "\n${YELLOW}Creating namespace...${NC}"
kubectl apply -f k8s/namespace.yaml
echo -e "${GREEN}Namespace created${NC}"

# Install k6 Operator
echo -e "\n${YELLOW}Installing k6 Operator...${NC}"
kubectl apply --server-side \
  -f https://raw.githubusercontent.com/grafana/k6-operator/main/bundle.yaml
echo -e "${GREEN}k6 Operator deployed${NC}"

# Pre-import k6 runner image
echo -e "\n${YELLOW}Importing k6 runner image into cluster...${NC}"
ARCH=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
docker pull --platform "linux/${ARCH}" grafana/k6:latest 2>&1 | tail -1
k3d image import grafana/k6:latest -c edge-observability 2>/dev/null || \
  echo -e "${YELLOW}k6 image import skipped — runner pod will pull from Docker Hub${NC}"

# Wait for k6 Operator
echo -e "\n${YELLOW}Waiting for k6 Operator controller...${NC}"
kubectl wait --for=condition=available deployment/k6-operator-controller-manager \
  -n k6-operator-system --timeout=120s
echo -e "${GREEN}k6 Operator ready${NC}"

# Apply k6 script ConfigMap
kubectl apply -f k8s/load-test/k6-script-configmap.yaml
echo -e "${GREEN}k6 script ConfigMap applied${NC}"

# Deploy Dash0 secret
echo -e "\n${YELLOW}Deploying Dash0 credentials...${NC}"
kubectl apply -f k8s/edge-node/dash0-secret.yaml
echo -e "${GREEN}Dash0 secret created${NC}"

# Deploy edge node components with Dash0 config
# (no hub-node backends needed — Dash0 replaces Jaeger, Prometheus, Loki, Grafana)
echo -e "\n${YELLOW}Deploying edge node components (Dash0 backend)...${NC}"
kubectl apply -f k8s/edge-node/app-deployment.yaml
kubectl apply -f k8s/edge-node/app-service.yaml
kubectl apply -f k8s/edge-node/fluentbit-config.yaml
kubectl apply -f k8s/edge-node/fluentbit-daemonset.yaml
kubectl apply -f k8s/edge-node/otel-collector-config-dash0.yaml
kubectl apply -f k8s/edge-node/otel-collector-daemonset-dash0.yaml
kubectl apply -f k8s/edge-node/otel-collector-service.yaml

echo -e "${YELLOW}Waiting for edge components to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app=otel-collector -n observability --timeout=300s
kubectl wait --for=condition=ready pod -l app=edge-demo-app -n observability --timeout=180s

echo -e "${GREEN}Edge components ready${NC}"

# Display cluster information
echo -e "\n${GREEN}Setup Complete (Dash0 backend)${NC}"
echo "=========================================="
echo ""
echo "  Backend: Dash0 (all signals via OTLP gRPC)"
echo "  No local Grafana/Jaeger/Prometheus/Loki deployed."
echo ""
echo "  View your data in Dash0:"
echo "    - Traces, metrics, and logs are all in your Dash0 org"
echo "    - All three signals have file-backed persistent queues"
echo "    - After network restore, ALL signals backfill (including metrics)"
echo ""

echo -e "\n${YELLOW}Cluster Status:${NC}"
kubectl get nodes -o wide
echo ""
kubectl get pods -n observability -o wide

echo -e "\n${YELLOW}Next Steps:${NC}"
echo "  1. Start load test:              ./scripts/load-generator.sh"
echo "  2. Run the orchestrated demo:    ./scripts/demo-dash0.sh"
echo "     (or manually: simulate → restore)"
echo "  3. Simulate network failure:     ./scripts/simulate-network-failure-dash0.sh"
echo "  4. Restore network:              ./scripts/restore-network-dash0.sh"
echo "  5. Cleanup:                      ./scripts/cleanup.sh"
echo ""
