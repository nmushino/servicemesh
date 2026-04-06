#!/bin/bash
# Kafkaに関するCRを一式インストールします。

set -e

PROJECT=kafka
CLUSTER=my-kafka
TOPIC1=input-topic
TOPIC2=output-topic
DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

echo "===== Create Project ====="
oc new-project ${PROJECT} || oc project ${PROJECT}

echo "===== Install AMQ Streams Operator ====="

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kafka-operator-group
  namespace: ${PROJECT}
spec:
  targetNamespaces:
  - ${PROJECT}
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: amq-streams
  namespace: ${PROJECT}
spec:
  channel: stable
  name: amq-streams
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

echo "===== Wait AMQ Streams Operator ====="

until oc get csv -n ${PROJECT} | grep amqstreams >/dev/null 2>&1
do
  echo "Waiting for AMQ Streams CSV..."
  sleep 10
done

echo "===== Create Kafka KRaft Cluster ====="

cat <<EOF | oc apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: ${CLUSTER}
  namespace: ${PROJECT}
  annotations:
    strimzi.io/kraft: enabled
    strimzi.io/node-pools: enabled
spec:
  kafka:
    version: 4.1.0
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: external
        port: 9094
        type: route
        tls: true
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      default.replication.factor: 3
      min.insync.replicas: 2
  entityOperator:
    topicOperator: {}
    userOperator: {}
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: controller
  namespace: ${PROJECT}
  labels:
    strimzi.io/cluster: ${CLUSTER}
spec:
  replicas: 3
  roles:
    - controller
  storage:
    type: ephemeral
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: broker
  namespace: ${PROJECT}
  labels:
    strimzi.io/cluster: ${CLUSTER}
spec:
  replicas: 3
  roles:
    - broker
  storage:
    type: ephemeral
EOF

echo "===== Wait Kafka Cluster Ready ====="

oc wait kafka/${CLUSTER} \
  --for=condition=Ready \
  -n ${PROJECT} \
  --timeout=120s

echo "===== Install Streams Console Operator ====="

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: amq-streams-console
  namespace: openshift-operators
spec:
  channel: stable
  name: amq-streams-console
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

echo "===== Wait Streams Console CRD ====="

until oc get csv -n openshift-operators | grep amq-streams-console >/dev/null 2>&1
do
  echo "Waiting for Streams Console CRD..."
  sleep 10
done

echo "===== Create Streams Console ====="

cat <<EOF | oc apply -f -
apiVersion: console.streamshub.github.com/v1alpha1
kind: Console
metadata:
  name: kafka-console
  namespace: ${PROJECT}
spec:
  hostname: kafka-console-${PROJECT}.${DOMAIN}
  kafkaClusters:
    - name: ${CLUSTER}
      namespace: ${PROJECT}
      listener: plain
EOF

echo "===== Create Topics ====="

cat <<EOF | oc apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: ${TOPIC1}
  namespace: ${PROJECT}
  labels:
    strimzi.io/cluster: ${CLUSTER}
spec:
  partitions: 3
  replicas: 3
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: ${TOPIC2}
  namespace: ${PROJECT}
  labels:
    strimzi.io/cluster: ${CLUSTER}
spec:
  partitions: 3
  replicas: 3
EOF

echo "===== Create Kafka Bridge ====="

cat <<EOF | oc apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaBridge
metadata:
  name: my-bridge
  namespace: ${PROJECT}
spec:
  replicas: 1
  bootstrapServers: my-kafka-kafka-bootstrap:9092
  http:
    port: 8080
EOF
oc expose svc my-bridge-bridge-service -n ${PROJECT}

echo "===== Done ====="
echo ""

echo "Check resources:"
echo "oc get pods -n ${PROJECT}"
echo "oc get kafka -n ${PROJECT}"
echo "oc get kafkatopic -n ${PROJECT}"
echo ""

if oc get route kafka-console -n ${PROJECT} >/dev/null 2>&1; then
  echo "Streams Console URL:"
  oc get route kafka-console -n ${PROJECT} -o jsonpath='{.spec.host}'
  echo ""
fi