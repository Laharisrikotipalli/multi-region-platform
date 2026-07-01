#!/usr/bin/env bash
# test-failover.sh
# Simulates a regional failure by scaling ap-southeast-1 to 0 replicas,
# then verifies Route 53 reroutes traffic to a healthy region within 120s.
set -euo pipefail

: "${ROUTE53_FQDN:?Set ROUTE53_FQDN (e.g. app.example.com)}"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; exit 1; }

aws eks update-kubeconfig --region ap-southeast-1 --name mr-eks-aps1 --kubeconfig /tmp/kc-aps1

# Pre-check
PRE=$(curl -sS --max-time 10 "https://${ROUTE53_FQDN}/health" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null)
[[ "$PRE" == "ok" ]] && ok "Pre-failover: platform healthy" || fail "Pre-failover health check failed"

log "=== Simulating ap-southeast-1 failure (scale to 0) ==="
KUBECONFIG=/tmp/kc-aps1 kubectl scale deployment webapp --replicas=0 -n multi-region
log "Waiting for Route 53 to reroute (up to 120s)..."

ELAPSED=0; REROUTED=false
while [[ $ELAPSED -lt 120 ]]; do
  sleep 10; ELAPSED=$((ELAPSED + 10))
  REGION=$(curl -sS --max-time 5 "https://${ROUTE53_FQDN}/info" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('region','unknown'))" 2>/dev/null \
    || echo "unknown")
  HTTP=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "https://${ROUTE53_FQDN}/health" \
    || echo "000")
  log "Elapsed: ${ELAPSED}s | HTTP: $HTTP | Region: $REGION"
  if [[ "$HTTP" == "200" && "$REGION" != "ap-southeast-1" && "$REGION" != "unknown" ]]; then
    ok "Traffic rerouted to $REGION after ${ELAPSED}s"
    REROUTED=true
    break
  fi
done

# Always restore ap-southeast-1
log "=== Restoring ap-southeast-1 ==="
KUBECONFIG=/tmp/kc-aps1 kubectl scale deployment webapp --replicas=3 -n multi-region
KUBECONFIG=/tmp/kc-aps1 kubectl rollout status deployment/webapp -n multi-region --timeout=120s
ok "ap-southeast-1 restored"

[[ "$REROUTED" != "true" ]] && fail "Traffic not rerouted within 120s"
echo ""
echo "FAILOVER TEST PASSED — rerouted in ${ELAPSED}s"