#!/bin/bash
set -e

PROJECT=connectivity-link
DEMO_NS=demo

# IngressGateway Service の EXTERNAL-IP / LoadBalancer Host 取得
LB_HOST=$(oc get svc connectivity-link-gateway-istio -n $PROJECT -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# ポートが 80 ならそのまま
URL="http://$LB_HOST/customerpoint"

# Kuadrant APIKey
API_KEY="my-secret-key"

echo "Route URL (LoadBalancer host):"
echo "$URL"
echo ""

# POST リクエスト送信 (APIKey 認証)
curl -v -X POST "$URL" \
     -H "Content-Type: text/plain" \
     -H "Authorization: Bearer my-secret-key" \
     -d "1000"