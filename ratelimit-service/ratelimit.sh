#!/bin/bash
set -e

# --------------------------------------------------
# Settings
# --------------------------------------------------
APP_NAME=customer-point-api
PROJECT=demo

BASE_DIR=$(pwd)
DOCKER_CONTEXT_DIR=${BASE_DIR}/build
DOCKERFILE_SRC=${BASE_DIR}/src/main/docker/Dockerfile
QUARKUS_TARGET=${BASE_DIR}/target/quarkus-app

ISTIO_NAMESPACE=istio-system
RATELIMIT_NAMESPACE=ratelimit

REDIS_IMAGE=redis:7.0

echo "===== OpenShift Login Check ====="
oc whoami

# --------------------------------------------------
# Project
# --------------------------------------------------
echo "===== Project ====="
oc new-project ${PROJECT} || oc project ${PROJECT}

oc label namespace ${PROJECT} \
  istio.io/dataplane-mode=ambient \
  --overwrite

# --------------------------------------------------
# Build App
# --------------------------------------------------
echo "===== Build ====="

oc delete bc ${APP_NAME} --ignore-not-found=true
oc delete is ${APP_NAME} --ignore-not-found=true

mvn clean package -DskipTests

rm -rf ${DOCKER_CONTEXT_DIR}
mkdir -p ${DOCKER_CONTEXT_DIR}

cp ${DOCKERFILE_SRC} ${DOCKER_CONTEXT_DIR}/Dockerfile
cp entrypoint.sh ${DOCKER_CONTEXT_DIR}/entrypoint.sh

mkdir -p ${DOCKER_CONTEXT_DIR}/quarkus-app
cp -r ${QUARKUS_TARGET}/* ${DOCKER_CONTEXT_DIR}/quarkus-app/

oc new-build --name=${APP_NAME} --binary --strategy=docker
oc start-build ${APP_NAME} --from-dir=${DOCKER_CONTEXT_DIR} --follow

# --------------------------------------------------
# Deploy App
# --------------------------------------------------
echo "===== Deploy App ====="

IMAGE_NAME=$(oc get istag ${APP_NAME}:latest \
  -o jsonpath='{.image.dockerImageReference}')

oc delete deployment ${APP_NAME} --ignore-not-found=true

cat <<EOF | oc apply -n ${PROJECT} -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ratelimit-config
data:
  RATELIMIT_WINDOW_SECONDS: "60"

  GOLD_LIMIT: "30"
  SILVER_LIMIT: "15"
  FREE_LIMIT: "5"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      containers:
      - name: ${APP_NAME}
        image: ${IMAGE_NAME}
        readinessProbe:
          tcpSocket:
            port: 9000
          initialDelaySeconds: 10
          periodSeconds: 5
        livenessProbe:
          tcpSocket:
            port: 9000
          initialDelaySeconds: 20
          periodSeconds: 10
        ports:
        - containerPort: 8080
        - containerPort: 9000
        env:
        - name: QUARKUS_REDIS_HOSTS
          value: redis://redis.${RATELIMIT_NAMESPACE}.svc.cluster.local:6379
        - name: QUARKUS_GRPC_SERVER_PORT
          value: "9000"
        envFrom:
        - configMapRef:
            name: ratelimit-config
EOF

oc rollout status deployment/${APP_NAME} -n ${PROJECT}

# --------------------------------------------------
# Service (App)
# --------------------------------------------------
cat <<EOF | oc apply -n ${PROJECT} -f -
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
spec:
  selector:
    app: ${APP_NAME}
  ports:
  - name: http
    port: 8080
    targetPort: 8080
  - name: grpc
    port: 9000
    targetPort: 9000
EOF

# --------------------------------------------------
# Redis
# --------------------------------------------------
echo "===== Redis ====="

oc create namespace ${RATELIMIT_NAMESPACE} || true

cat <<EOF | oc apply -n ${RATELIMIT_NAMESPACE} -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: ratelimit
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: ${REDIS_IMAGE}
        ports:
        - containerPort: 6379
        args:
          - "--save"
          - ""
          - "--appendonly"
          - "no"
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: ratelimit
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379

EOF

oc label gateway external-gateway -n istio-system \
  gateway.networking.k8s.io/gateway-name=external-gateway \
  --overwrite

# --------------------------------------------------
# EnvoyFilter
# --------------------------------------------------
echo "===== EnvoyFilter ====="

cat <<EOF | oc apply -n ${ISTIO_NAMESPACE} -f -
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: ratelimit
  namespace: istio-system
spec:
  workloadSelector:
    labels:
      gateway.networking.k8s.io/gateway-name: external-gateway
  configPatches:

  # ------------------------------------------------
  # HTTP FILTER
  # ------------------------------------------------
  - applyTo: HTTP_FILTER
    match:
      context: GATEWAY
      listener:
        filterChain:
          filter:
            name: envoy.filters.network.http_connection_manager
            subFilter:
              name: envoy.filters.http.router
    patch:
      operation: INSERT_BEFORE
      value:
        name: envoy.filters.http.ratelimit
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.http.ratelimit.v3.RateLimit
          domain: customerpoint
          failure_mode_deny: false
          rate_limit_service:
            transport_api_version: V3
            grpc_service:
              envoy_grpc:
                cluster_name: ratelimit_cluster

  # ------------------------------------------------
  # RATE LIMIT CLUSTER
  # ------------------------------------------------
  - applyTo: CLUSTER
    match:
      context: GATEWAY
    patch:
      operation: ADD
      value:
        name: ratelimit_cluster
        type: STRICT_DNS
        connect_timeout: 5s
        lb_policy: ROUND_ROBIN
        http2_protocol_options: {}
        load_assignment:
          cluster_name: ratelimit_cluster
          endpoints:
          - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: customer-point-api.demo.svc.cluster.local
                    port_value: 9000

  # -------------------------
  # VIRTUAL HOST
  # -------------------------
  - applyTo: VIRTUAL_HOST
    match:
      context: GATEWAY
      route_configuration:
        vhost:
          name: "*:80"
    patch:
      operation: MERGE
      value:
        rate_limits:
        - actions:
          - request_headers:
              header_name: x-tenant
              descriptor_key: tenant
EOF

echo "===== DONE ====="