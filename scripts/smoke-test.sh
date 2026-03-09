#!/usr/bin/env bash
# scripts/smoke-test.sh
# Usage: bash scripts/smoke-test.sh <BASE_URL>
# BASE_URL examples:
#   dev:     http://cicd-demo-alb.us-east-1.elb.amazonaws.com/dev
#   staging: http://cicd-demo-alb.us-east-1.elb.amazonaws.com/staging
#   prod:    http://cicd-demo-alb.us-east-1.elb.amazonaws.com
set -euo pipefail

BASE_URL="${1:?Usage: smoke-test.sh <BASE_URL>}"
BASE_URL="${BASE_URL%/}"   # strip trailing slash

MAX_RETRIES=12
RETRY_INTERVAL=10

echo "============================================"
echo "  Smoke Test: ${BASE_URL}"
echo "============================================"

check_url() {
  local url="$1"
  local expect_body="$2"
  local attempt=0

  while [[ $attempt -lt $MAX_RETRIES ]]; do
    attempt=$((attempt + 1))
    echo "[attempt ${attempt}/${MAX_RETRIES}] GET ${url}"

    HTTP_STATUS=$(curl -s -o /tmp/smoke_body.txt -w "%{http_code}" \
      --max-time 10 --connect-timeout 5 --location \
      "${url}" || echo "000")

    if [[ "${HTTP_STATUS}" == "200" ]]; then
      if grep -q "${expect_body}" /tmp/smoke_body.txt; then
        echo "  ✅ HTTP 200 + body contains '${expect_body}'"
        return 0
      else
        echo "  ⚠️  HTTP 200 but body missing '${expect_body}'"
        echo "  Body: $(head -c 200 /tmp/smoke_body.txt)"
      fi
    else
      echo "  ⚠️  HTTP ${HTTP_STATUS} — retrying in ${RETRY_INTERVAL}s…"
    fi

    sleep "${RETRY_INTERVAL}"
  done

  echo "  ❌ Smoke test FAILED after ${MAX_RETRIES} attempts: ${url}"
  return 1
}

# Test 1: main page — no trailing slash to avoid 308 redirect
echo ""
echo "→ Test 1: root page"
check_url "${BASE_URL}" "Hello from CI/CD"

# Test 2: health.json — served under the same base path
echo ""
echo "→ Test 2: health check"
check_url "${BASE_URL}/health.json" '"status":"ok"'

echo ""
echo "============================================"
echo "  ✅ All smoke tests passed"
echo "============================================"