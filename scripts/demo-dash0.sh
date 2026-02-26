#!/bin/bash
# ============================================================
#  demo-dash0.sh — Orchestrated live demo (Dash0 backend)
#  "Making Observability Work at the Edge" — KubeCon EU 2026
#
#  Same three-act structure as demo.sh but queries Dash0's
#  Prometheus-compatible API instead of a local Prometheus,
#  and directs the presenter to Dash0 UI instead of Grafana/Jaeger.
#
#  Usage:
#    ./scripts/demo-dash0.sh          # full run (Act 1 → 2 → 3)
#    ./scripts/demo-dash0.sh 2        # start from Act 2
#    ./scripts/demo-dash0.sh 3        # start from Act 3 (failure/restore only)
#
#  Requires: kubectl, curl, python3, docker
#  Environment:
#    DASH0_AUTH_TOKEN  — Bearer token (reads from k8s secret if not set)
#    DASH0_API_URL     — API base URL (reads from k8s secret if not set)
# ============================================================

set -euo pipefail

# ── Constants ──────────────────────────────────────────────
NAMESPACE="observability"
EDGE_NODE="k3d-edge-observability-agent-0"
TESTRUN_NAME="vessel-monitoring"
FAILURE_DURATION=90
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colors ─────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'
DIM='\033[2m';  NC='\033[0m';   BOLD='\033[1m'

# ── State ──────────────────────────────────────────────────
FAILURE_START=0
FAILURE_END=0
RESTORE_TIME=0
CHECKS_PASSED=0
CHECKS_FAILED=0
FAILED_CHECKS=()

# ── Formatting ─────────────────────────────────────────────
header() {
  local title="$1"
  local width=56
  local pad=$(( (width - ${#title} - 2) / 2 ))
  echo ""
  echo -e "${W}╔$(printf '═%.0s' $(seq 1 $width))╗${NC}"
  printf "${W}║%*s${BOLD}%s${W}%*s║${NC}\n" $pad "" "$title" $(( width - pad - ${#title} )) ""
  echo -e "${W}╚$(printf '═%.0s' $(seq 1 $width))╝${NC}"
}

section() {
  echo -e "\n${C}${BOLD}▶ $1${NC}"
  echo -e "${DIM}$(printf '─%.0s' $(seq 1 56))${NC}"
}

ok()   { echo -e "  ${G}✓${NC} $1"; (( CHECKS_PASSED++ )) || true; }
fail() { echo -e "  ${R}✗${NC} $1"; (( CHECKS_FAILED++ )) || true; FAILED_CHECKS+=("$1"); }
warn() { echo -e "  ${Y}⚠${NC} $1"; }
info() { echo -e "  ${B}ℹ${NC} $1"; }

dash0_box() {
  echo -e "\n  ${Y}┌─ DASH0 ──────────────────────────────────────────┐${NC}"
  while IFS= read -r line; do
    echo -e "  ${Y}│${NC}  $line"
  done <<< "$1"
  echo -e "  ${Y}└───────────────────────────────────────────────────┘${NC}"
}

press_enter() {
  echo -e "\n  ${DIM}Press Enter when ready to continue...${NC}"
  read -r
}

# ── Dash0 credentials ──────────────────────────────────────
load_dash0_creds() {
  if [ -z "${DASH0_AUTH_TOKEN:-}" ]; then
    DASH0_AUTH_TOKEN=$(kubectl get secret dash0-credentials -n "${NAMESPACE}" \
      -o jsonpath='{.data.auth-token}' 2>/dev/null | base64 -d) || true
  fi
  if [ -z "${DASH0_API_URL:-}" ]; then
    DASH0_API_URL=$(kubectl get secret dash0-credentials -n "${NAMESPACE}" \
      -o jsonpath='{.data.api-url}' 2>/dev/null | base64 -d) || true
  fi

  if [ -z "${DASH0_AUTH_TOKEN}" ] || [ -z "${DASH0_API_URL}" ]; then
    fail "Dash0 credentials not found. Set DASH0_AUTH_TOKEN and DASH0_API_URL env vars, or configure k8s/edge-node/dash0-secret.yaml"
    exit 1
  fi
}

# ── Dash0 Prometheus API helpers ────────────────────────────
# Dash0 implements the Prometheus API under /api/prometheus/api/v1/
dash0_prom_value() {
  local query="$1"
  curl -sf -X POST "${DASH0_API_URL}/api/prometheus/api/v1/query" \
    -H "Authorization: ${DASH0_AUTH_TOKEN}" \
    --data-urlencode "query=${query}" 2>/dev/null \
  | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  r = d.get('data', {}).get('result', [])
  print(float(r[0]['value'][1]) if r else 0.0)
except:
  print(0.0)
" 2>/dev/null || echo "0"
}

wait_for_metric() {
  local query="$1" op="$2" threshold="$3" timeout="$4" label="$5"
  local start=$SECONDS last_val=0

  while true; do
    last_val=$(dash0_prom_value "${query}")

    local ok_flag=0
    case "$op" in
      gt) python3 -c "exit(0 if ${last_val} >  ${threshold} else 1)" 2>/dev/null && ok_flag=1 || true ;;
      lt) python3 -c "exit(0 if ${last_val} <  ${threshold} else 1)" 2>/dev/null && ok_flag=1 || true ;;
      ge) python3 -c "exit(0 if ${last_val} >= ${threshold} else 1)" 2>/dev/null && ok_flag=1 || true ;;
      eq) python3 -c "exit(0 if ${last_val} == ${threshold} else 1)" 2>/dev/null && ok_flag=1 || true ;;
    esac

    if [[ $ok_flag -eq 1 ]]; then
      ok "${label} (value=${last_val})"
      return 0
    fi

    if [[ $(( SECONDS - start )) -ge $timeout ]]; then
      warn "${label} — timeout ${timeout}s, last value=${last_val}"
      return 1
    fi

    sleep 5
  done
}

countdown_monitoring() {
  local total=$1
  local start=$SECONDS
  echo ""
  while [[ $(( SECONDS - start )) -lt $total ]]; do
    local remaining=$(( total - SECONDS + start ))
    local queue
    local throughput
    queue=$(dash0_prom_value 'sum(otelcol_exporter_queue_size) or vector(0)')
    throughput=$(dash0_prom_value 'rate(otelcol_exporter_sent_spans{exporter="otlp/dash0"}[30s])')
    printf "  ${Y}⏱ %3ds${NC}  │  ${B}Queue: %3s batches${NC}  │  ${R}Span throughput: %5.1f /s${NC}  \r" \
      "$remaining" "$queue" "$throughput"
    sleep 5
  done
  printf "\n"
}

# ── Pre-flight ──────────────────────────────────────────────
preflight() {
  section "Pre-flight checks"

  local ctx
  ctx=$(kubectl config current-context 2>/dev/null || echo "none")
  if [[ "$ctx" == *"edge-observability"* ]]; then
    ok "kubectl context: ${ctx}"
  else
    fail "Wrong context '${ctx}'. Expected 'k3d-edge-observability'. Run setup-dash0.sh."
    exit 1
  fi

  kubectl get namespace "${NAMESPACE}" &>/dev/null \
    && ok "Namespace '${NAMESPACE}' exists" \
    || { fail "Namespace '${NAMESPACE}' missing — run ./scripts/setup-dash0.sh"; exit 1; }

  local not_running
  not_running=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | { grep -v -E "(Running|Completed|Succeeded)" || true; } \
    | { grep -v "^$" || true; } \
    | wc -l | tr -d ' ')
  if [[ "$not_running" -eq 0 ]]; then
    ok "All pods Running"
  else
    warn "${not_running} pod(s) not Running — check: kubectl get pods -n ${NAMESPACE}"
  fi

  if kubectl exec -n "${NAMESPACE}" deployment/edge-demo-app -- \
       wget -qO- http://localhost:8080/health &>/dev/null; then
    ok "edge-demo-app is responding"
  else
    fail "edge-demo-app not responding — check app pod logs"
  fi

  # Verify Dash0 API connectivity
  local dash0_code
  dash0_code=$(curl -sf -o /dev/null -w "%{http_code}" \
    "${DASH0_API_URL}/api/prometheus/api/v1/query" \
    -H "Authorization: ${DASH0_AUTH_TOKEN}" \
    --data-urlencode "query=up" 2>/dev/null || echo "000")
  if [[ "$dash0_code" == "200" ]]; then
    ok "Dash0 Prometheus API accessible"
  else
    fail "Dash0 API not accessible (HTTP ${dash0_code}) — check credentials"
  fi

  # Check OTel Collector metrics in Dash0
  local spans_rcvd
  spans_rcvd=$(dash0_prom_value 'otelcol_receiver_accepted_spans')
  if python3 -c "exit(0 if float('${spans_rcvd}') > 0 else 1)" 2>/dev/null; then
    ok "OTel Collector metrics in Dash0 (accepted_spans=${spans_rcvd})"
  else
    warn "OTel Collector metrics not yet in Dash0 — data may be starting up"
  fi

  local stale_rules
  stale_rules=$(docker exec "${EDGE_NODE}" \
    iptables -L FORWARD -n 2>/dev/null | { grep -c DROP || true; })
  if [[ "$stale_rules" -eq 0 ]]; then
    ok "No stale iptables DROP rules on edge node"
  else
    warn "${stale_rules} DROP rule(s) still in FORWARD chain — run ./scripts/restore-network-dash0.sh"
  fi
}

# ── Load test ───────────────────────────────────────────────
ensure_load_test() {
  section "Load test (k6 Operator)"

  local stage
  stage=$(kubectl get testrun "${TESTRUN_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.stage}' 2>/dev/null || echo "not-found")

  case "$stage" in
    "started")
      local runner_pod
      runner_pod=$(kubectl get pods -n "${NAMESPACE}" -l "k6_cr=${TESTRUN_NAME}" \
        --no-headers 2>/dev/null | head -1 | awk '{print $1}')
      ok "TestRun '${TESTRUN_NAME}' is running (pod: ${runner_pod:-?})"
      ;;
    "finished"|"stopped"|"error")
      warn "TestRun stage is '${stage}'. Recreating..."
      bash "${SCRIPT_DIR}/load-generator.sh"
      ;;
    "not-found")
      info "TestRun not found — starting load test..."
      bash "${SCRIPT_DIR}/load-generator.sh"
      ;;
    *)
      info "TestRun stage: '${stage}' (still initializing, waiting up to 60s)..."
      local start=$SECONDS
      while [[ $(( SECONDS - start )) -lt 60 ]]; do
        stage=$(kubectl get testrun "${TESTRUN_NAME}" -n "${NAMESPACE}" \
          -o jsonpath='{.status.stage}' 2>/dev/null || echo "")
        [[ "$stage" == "started" ]] && { ok "TestRun started"; return 0; }
        sleep 5
      done
      warn "TestRun not yet started after 60s — continuing anyway"
      ;;
  esac
}

wait_baseline() {
  echo ""
  echo -e "  ${DIM}Waiting 30s for baseline data to accumulate in Dash0...${NC}"
  for ((i=30; i>0; i--)); do
    printf "  %3ds remaining\r" "$i"; sleep 1
  done
  printf "\n"
}

# ── Act 1 ───────────────────────────────────────────────────
act1_guide() {
  header "ACT 1 — The system works (~5 min)"

  dash0_box "Open Dash0 Dashboards → Vessel Operations
Shows real metrics (unsampled) — the true operational picture."

  echo ""
  echo -e "  ${W}What to show in Dash0:${NC}"
  echo -e "    ${G}Vessel Operations dashboard${NC}  request rate, error rate, latency, logs"
  echo -e "    ${G}Tracing view${NC}                 search for service=edge-demo-app"
  echo -e "    ${G}Services view${NC}                span-based overview (see note below)"
  echo ""
  echo -e "  ${W}Key observations:${NC}"
  echo -e "    - /alerts endpoint has a 20% simulated failure rate (sensor comm errors)"
  echo -e "    - Only 8% of traffic hits /alerts, so real error rate ~1.6%"
  echo -e "    - Diagnostics endpoint visibly slower (300-1500ms)"
  echo -e "    - Logs show ONLY errors + slow requests (Fluent Bit filtered the rest)"
  echo -e "    - Click any trace_id in logs to jump to the full trace"
  echo ""
  echo -e "  ${Y}Note on the Services page:${NC}"
  echo -e "    The Services page is span-based — it shows error rates derived from"
  echo -e "    traces, not metrics. Because tail sampling drops successful fast traces"
  echo -e "    at the edge, the Services page will show an inflated error rate."
  echo -e "    The real error rate is in the metrics (unsampled). This contrast is"
  echo -e "    the whole point of Act 2."
  echo ""

  local drop_pct
  drop_pct=$(dash0_prom_value \
    '(1 - sum(rate(otelcol_exporter_sent_spans[2m])) / sum(rate(otelcol_receiver_accepted_spans[2m]))) * 100')
  printf "  ${DIM}Live: tail sampling is dropping %.0f%% of spans right now${NC}\n" "$drop_pct"

  echo ""
  echo -e "  ${DIM}\"Every log entry here represents something worth looking at.${NC}"
  echo -e "  ${DIM}The thousands of 'engine reading normal' logs never leave the edge node.\"${NC}"

  press_enter
}

# ── Act 2 ───────────────────────────────────────────────────
act2_guide() {
  header "ACT 2 — We don't send everything (~7 min)"

  dash0_box "Open Dash0 Dashboards → Edge Pipeline → SAMPLING section
Compare received vs exported spans to see the sampling gap."

  echo ""
  echo -e "  ${W}Sampling reduction:${NC}"
  local drop_pct
  drop_pct=$(dash0_prom_value \
    '(1 - sum(rate(otelcol_exporter_sent_spans[2m])) / sum(rate(otelcol_receiver_accepted_spans[2m]))) * 100')
  printf "    ${Y}Current: %.0f%%${NC} of spans dropped  (target: ~70-80%%)\n" "$drop_pct"
  echo ""
  echo -e "  ${W}In Dash0 Edge Pipeline dashboard → SAMPLING section:${NC}"
  echo -e "    ${G}rate(otelcol_receiver_accepted_spans[2m])${NC}  — what the collector receives"
  echo -e "    ${G}rate(otelcol_exporter_sent_spans[2m])${NC}     — what leaves the edge"
  echo -e "    The gap is what tail sampling drops."
  echo ""
  echo -e "  ${W}Sampling policies:${NC}"
  echo -e "    ${G}error-policy${NC}    → keep 100% of ERROR traces"
  echo -e "    ${G}latency-policy${NC}  → keep 100% of traces >200ms"
  echo -e "    ${R}everything else${NC} → dropped (~80% of traffic)"
  echo ""
  echo -e "  ${W}Key difference from Grafana setup:${NC}"
  echo -e "    All three signals (traces, metrics, logs) go through a single"
  echo -e "    OTLP exporter with file-backed queues. Metrics now have"
  echo -e "    persistent queuing too — no more metric gap on restore."
  echo ""
  echo -e "  ${DIM}\"Two deterministic policies. No random sampling —${NC}"
  echo -e "  ${DIM}no blind spots for things that matter.\"${NC}"

  press_enter
}

# ── Act 3: failure ──────────────────────────────────────────
act3_failure() {
  header "ACT 3 — Link failure simulation"

  dash0_box "Open Dash0 Dashboards → Edge Pipeline → RESILIENCE section
Watch 'Queue Depth' rise after the link drops."

  echo ""
  echo -e "  ${DIM}Press Enter to apply iptables DROP rules and cut the link...${NC}"
  read -r

  echo ""
  echo -e "  ${B}→ Blocking OTel Collector → Dash0 (outbound OTLP + TLS)${NC}"
  bash "${SCRIPT_DIR}/simulate-network-failure-dash0.sh"
  FAILURE_START=$(date +%s)

  echo ""
  echo -e "  ${R}$(printf '━%.0s' $(seq 1 56))${NC}"
  echo -e "  ${R}  LINK DOWN — collector cannot reach Dash0${NC}"
  echo -e "  ${R}$(printf '━%.0s' $(seq 1 56))${NC}"

  # Note: once the link is down, we can't query Dash0's API either.
  # We query the collector's own metrics endpoint directly instead.
  echo ""
  echo -e "  ${B}→ Verifying collector is queuing (checking local metrics)...${NC}"
  sleep 15

  local queue_size
  queue_size=$(kubectl exec -n "${NAMESPACE}" -l app=otel-collector -- \
    wget -qO- http://localhost:8888/metrics 2>/dev/null \
    | grep 'otelcol_exporter_queue_size{' | head -1 \
    | awk '{print $2}' || echo "0")
  if python3 -c "exit(0 if float('${queue_size}') > 0 else 1)" 2>/dev/null; then
    ok "Queue building up (local queue_size=${queue_size})"
  else
    warn "Queue not yet visible — may need more time"
  fi

  # Show file storage
  echo ""
  echo -e "  ${B}→ File storage on edge node (queued batches):${NC}"
  docker exec "${EDGE_NODE}" ls -lah /var/lib/otelcol/file_storage/ 2>/dev/null \
    | sed 's/^/    /' || warn "Could not read file storage"

  echo ""
  echo -e "  ${Y}Holding for ${FAILURE_DURATION}s — queue depth rising on disk${NC}"
  echo -e "  ${DIM}(Cannot query Dash0 while link is down — monitoring locally)${NC}"

  # Local countdown using collector's own metrics
  local start=$SECONDS
  echo ""
  while [[ $(( SECONDS - start )) -lt $FAILURE_DURATION ]]; do
    local remaining=$(( FAILURE_DURATION - SECONDS + start ))
    queue_size=$(kubectl exec -n "${NAMESPACE}" -l app=otel-collector -- \
      wget -qO- http://localhost:8888/metrics 2>/dev/null \
      | grep 'otelcol_exporter_queue_size{' \
      | awk '{sum+=$2} END {print sum+0}' || echo "0")
    printf "  ${Y}⏱ %3ds${NC}  │  ${B}Queue: %s batches${NC}  \r" \
      "$remaining" "$queue_size"
    sleep 5
  done
  printf "\n"

  # Snapshot file storage at end of outage
  echo ""
  echo -e "  ${B}→ File storage after ${FAILURE_DURATION}s outage:${NC}"
  docker exec "${EDGE_NODE}" ls -lah /var/lib/otelcol/file_storage/ 2>/dev/null \
    | sed 's/^/    /' || warn "Could not read file storage"

  FAILURE_END=$(date +%s)
  local duration=$(( FAILURE_END - FAILURE_START ))
  echo ""
  info "Failure window: $(date -r "$FAILURE_START" '+%H:%M:%S') → $(date -r "$FAILURE_END" '+%H:%M:%S') (${duration}s)"
}

# ── Act 3: restore ──────────────────────────────────────────
act3_restore() {
  echo ""
  echo -e "  ${DIM}Press Enter to restore the satellite link...${NC}"
  read -r

  echo ""
  echo -e "  ${B}→ Removing iptables DROP rules...${NC}"
  bash "${SCRIPT_DIR}/restore-network-dash0.sh"
  RESTORE_TIME=$(date +%s)

  echo ""
  echo -e "  ${G}$(printf '━%.0s' $(seq 1 56))${NC}"
  echo -e "  ${G}  LINK RESTORED — file-backed queue draining to Dash0${NC}"
  echo -e "  ${G}$(printf '━%.0s' $(seq 1 56))${NC}"

  dash0_box "In Dash0 Dashboards, set time range to 'last 30 minutes':
Vessel Operations: metrics gap FILLS (Dash0 accepts out-of-order)
Edge Pipeline → RESILIENCE: queue drains, throughput spikes
Tracing: failure-window traces appear with original timestamps
All three signals fully recover."

  # Wait for queue to drain (now we can query Dash0 again)
  echo ""
  echo -e "  ${B}→ Waiting for queue to drain (timeout 120s)...${NC}"
  wait_for_metric \
    'sum(otelcol_exporter_queue_size) or vector(0)' \
    "lt" "1" 120 "Queue drained (all signals = 0)" || true

  # Verify throughput spike
  sleep 10
  echo ""
  echo -e "  ${B}→ Verifying throughput spike (queue drain burst)...${NC}"
  local peak baseline
  peak=$(dash0_prom_value \
    'max_over_time(rate(otelcol_exporter_sent_spans{exporter="otlp/dash0"}[30s])[3m:])')
  baseline=$(dash0_prom_value \
    'avg_over_time(rate(otelcol_exporter_sent_spans{exporter="otlp/dash0"}[2m])[10m:2m])')

  if python3 -c "exit(0 if float('${peak}') > max(float('${baseline}') * 1.5, 0.5) else 1)" \
       2>/dev/null; then
    ok "Throughput spike confirmed (peak=${peak}, baseline≈${baseline} spans/s)"
  else
    warn "Spike not conclusive (peak=${peak}, baseline≈${baseline}) — may have settled already"
  fi

  # Dashboard summary
  echo ""
  echo -e "  ${W}What to show now in Dash0:${NC}"
  echo -e ""
  echo -e "  ${G}Tracing view:${NC}"
  echo -e "    - Filter time range to the failure window"
  echo -e "    - Traces from the outage appear with original timestamps"
  echo -e ""
  echo -e "  ${G}Metrics explorer:${NC}"
  echo -e "    - http.server.request.count: gap FILLS (all three signals recover)"
  echo -e "    - otelcol_exporter_queue_size: back to 0"
  echo -e ""
  echo -e "  ${G}Logs view:${NC}"
  echo -e "    - Failure-window log entries reappear"
  echo -e "    - Click trace_id to jump to the recovered trace"
  echo ""
  echo -e "  ${DIM}\"All three signals fully recover. Unlike the Grafana setup where${NC}"
  echo -e "  ${DIM}the metric gap stays, Dash0 accepts out-of-order samples.${NC}"
  echo -e "  ${DIM}The single OTLP exporter with file-backed queues means${NC}"
  echo -e "  ${DIM}metrics get the same resilience as traces and logs.\"${NC}"
}

# ── Summary ─────────────────────────────────────────────────
show_summary() {
  header "Demo Summary"
  echo ""

  if [[ ${CHECKS_FAILED} -eq 0 ]]; then
    echo -e "  ${G}${BOLD}All checks passed${NC} (${CHECKS_PASSED} total)"
  else
    echo -e "  ${Y}${CHECKS_PASSED} passed  ${R}${CHECKS_FAILED} failed${NC}"
    for c in "${FAILED_CHECKS[@]}"; do
      echo -e "    ${R}✗${NC} ${c}"
    done
  fi

  echo ""
  if [[ $FAILURE_START -gt 0 ]]; then
    echo -e "  Failure window : $(date -r "$FAILURE_START" '+%H:%M:%S') → $(date -r "$FAILURE_END" '+%H:%M:%S') (${FAILURE_DURATION}s)"
    echo -e "  Link restored  : $(date -r "$RESTORE_TIME" '+%H:%M:%S')"
    echo -e "  Queue drain    : ~$((RESTORE_TIME - FAILURE_END))s after restore"
  fi

  echo ""
  echo -e "  ${W}Key improvement over Grafana backend:${NC}"
  echo -e "    All 3 signals have file-backed queues (metrics included)"
  echo -e "    All 3 signals backfill after restore (no metric gap)"

  echo ""
  echo -e "  ${DIM}Load test still running. To stop:${NC}"
  echo -e "  ${DIM}  kubectl delete testrun ${TESTRUN_NAME} -n ${NAMESPACE}${NC}"
  echo ""
}

# ── Entry point ─────────────────────────────────────────────
START_ACT="${1:-1}"

if ! [[ "$START_ACT" =~ ^[123]$ ]]; then
  echo "Usage: $(basename "$0") [1|2|3]"
  echo "  1  Full run: pre-flight → Act 1 → Act 2 → Act 3  (default)"
  echo "  2  Start at Act 2 (sampling)"
  echo "  3  Start at Act 3 (failure/restore only)"
  exit 1
fi

header "Making Observability Work at the Edge"
echo -e "  ${DIM}KubeCon EU 2026 — orchestrated demo runner (Dash0 backend)${NC}"

load_dash0_creds
echo -e "  ${DIM}Dash0 API: ${DASH0_API_URL}${NC}"

preflight

case "$START_ACT" in
  1)
    ensure_load_test
    wait_baseline
    act1_guide
    act2_guide
    act3_failure
    act3_restore
    ;;
  2)
    ensure_load_test
    act2_guide
    act3_failure
    act3_restore
    ;;
  3)
    act3_failure
    act3_restore
    ;;
esac

show_summary
