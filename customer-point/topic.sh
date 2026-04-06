#!/bin/bash
# kcat.sh - OpenShift Kafka に外部からデータを送信する

set -e

NAMESPACE=kafka
APP_NAME=my-bridge-bridge-service
CENTER=$1
COUNT=${2:-1}
RANGE=50

# Route のホスト名を取得
ROUTE_HOST=$(oc get route $APP_NAME -n $NAMESPACE -o jsonpath='{.spec.host}')
# Route URL を作成
ROUTE_URL="http://$ROUTE_HOST/topics/input-topic"

for i in $(seq 1 $COUNT); do
  VALUE=$(( CENTER + RANDOM % (2*RANGE+1) - RANGE ))
  VALUE_PADDED=$(printf "%06d" "$VALUE")

  curl -s -X POST "$ROUTE_URL" \
    -H "content-type: application/vnd.kafka.text.v2+json" \
    -d "{\"records\":[{\"value\":\"$VALUE_PADDED\"}]}"
done