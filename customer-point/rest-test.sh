#!/bin/bash
set -e

#######################################################
# リクエストプランは、下記のプランで実行することが可能
#  * gold 30/min
#  * silver 15/min
#  * free 5/min
#
#  具体的には-H "x-tenant: free" と設定する
#
#######################################################


ELB_HOST=$(oc get svc external-gateway-istio \
  -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

HOST_HEADER=$(oc get route istio-ingressgateway \
  -n istio-system \
  -o jsonpath='{.spec.host}')

URL="http://${ELB_HOST}/customerpoint"

echo "===== Sliding Window Test ====="
echo "URL: $URL"
echo ""

request() {

  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$URL" \
    -H "Host: ${HOST_HEADER}" \
    -H "Content-Type: text/plain" \
    -H "x-tenant: free" \
    -d "1000")

  echo "$(date '+%H:%M:%S') -> $STATUS"
}

echo ""
echo "=== Burst 30 requests ==="

for i in {1..30}; do
  request
  sleep 0.5
done

echo ""
echo "=== Wait 15 sec ==="
sleep 15

echo ""
echo "=== Retry ==="

for i in {1..30}; do
  request
  sleep 0.5
done

echo ""
echo "=== Wait 30 sec ==="
sleep 30

echo ""
echo "=== Retry after window expired ==="

for i in {1..30}; do
  request
  sleep 0.5
done