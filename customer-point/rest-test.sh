#!/bin/bash

set -e

NAMESPACE=demo
APP_NAME=customer-point-api


# curl でアクセス
# curl -X POST "$ROUTE_URL" -H "Content-Type: text/plain" -d "1000"


echo "===== Get Ingress Gateway Route ====="

INGRESS_HOST=$(oc get route istio-ingressgateway -n istio-system -o jsonpath='{.spec.host}')

if [ -z "$INGRESS_HOST" ]; then
  echo "❌ Ingress Gateway Route not found"
  exit 1
fi

URL="http://${INGRESS_HOST}/customerpoint"

echo "===== Test URL ====="
echo "URL: $URL"
echo ""

for i in {1..20}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$URL" \
    -H "Host: ${INGRESS_HOST}" \
    -H "Content-Type: text/plain" \
    -d "1000")

  echo "Request $i: $STATUS"
  sleep 0.2
done