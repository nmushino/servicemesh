#!/bin/bash
set -e

ELB_HOST="a19272be2e8bf4bdbac50cac1ecfaaa9-60525830.us-east-2.elb.amazonaws.com"
HOST_HEADER=$(oc get route istio-ingressgateway -n istio-system -o jsonpath='{.spec.host}')

URL="http://${ELB_HOST}/customerpoint"

echo "===== Test URL ====="
echo "URL: $URL"
echo "Host: $HOST_HEADER"
echo ""

for i in {1..20}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$URL" \
    -H "Host: ${HOST_HEADER}" \
    -H "Content-Type: text/plain" \
    -d "1000")

  echo "Request $i: $STATUS"

  sleep 0.2
done