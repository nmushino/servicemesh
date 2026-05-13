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
RATELIMIT_IMAGE=envoyproxy/ratelimit:master

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
        ports:
        - containerPort: 8080
        - containerPort: 9000
        env:
        - name: QUARKUS_REDIS_HOSTS
          value: redis://redis.${RATELIMIT_NAMESPACE}.svc.cluster.local:6379
        - name: QUARKUS_GRPC_SERVER_PORT
          value: "9000"
        - name: RATELIMIT_WINDOW_MS
          value: "60000"
        - name: RATELIMIT_MAX_REQUESTS
          value: "4"
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
EOF

# --------------------------------------------------
# Redis + RateLimit backend
# --------------------------------------------------
echo "===== Redis & RateLimit ====="

oc create namespace ${RATELIMIT_NAMESPACE} || true

cat <<EOF | oc apply -n ${RATELIMIT_NAMESPACE} -f -

# -------------------------
# Redis
# -------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: ${RATELIMIT_NAMESPACE}
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
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: ${RATELIMIT_NAMESPACE}
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379

# -------------------------
# ConfigMap (IMPORTANT)
# -------------------------
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ratelimit-config
  namespace: ${RATELIMIT_NAMESPACE}
data:
  config.yaml: |
    domain: customerpoint
    descriptors:
      - key: generic_key
        value: customerpoint
        rate_limit:
          unit: minute
          requests_per_unit: 4

# -------------------------
# RateLimit Service
# -------------------------
---
apiVersion: v1
kind: Service
metadata:
  name: ratelimit
  namespace: ${RATELIMIT_NAMESPACE}
spec:
  selector:
    app: ratelimit
  ports:
  - name: grpc
    port: 8081
    targetPort: 8081

# -------------------------
# RateLimit Deployment (FIXED)
# -------------------------
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ratelimit
  namespace: ${RATELIMIT_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ratelimit
  template:
    metadata:
      labels:
        app: ratelimit
    spec:
      containers:
      - name: ratelimit
        image: ${RATELIMIT_IMAGE}
        ports:
        - containerPort: 8081

        env:çç
        - name: CONFIG_TYPE
          value: FILE
        - name: RUNTIME_ROOT
          value: /data
        - name: RUNTIME_SUBDIRECTORY
          value: ratelimit

        - name: REDIS_SOCKET_TYPE
          value: tcp
        - name: REDIS_URL
          value: redis://redis.${RATELIMIT_NAMESPACE}.svc.cluster.local:6379

        - name: USE_STATSD
          value: "false"
        - name: USE_REDIS
          value: "true"

        volumeMounts:
        - name: config
          mountPath: /data/ratelimit
          readOnly: true

      volumes:
      - name: config
        configMap:
          name: ratelimit-config
          items:
          - key: config.yaml
            path: config.yaml
EOF

# --------------------------------------------------
# Gateway label
# --------------------------------------------------
oc label gateway external-gateway -n ${ISTIO_NAMESPACE} \
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
  namespace: ${ISTIO_NAMESPACE}

spec:
  workloadSelector:
    labels:
      gateway.networking.k8s.io/gateway-name: external-gateway

  configPatches:

  # HTTP FILTER
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

  # CLUSTER
  - applyTo: CLUSTER
    match:
      context: GATEWAY
    patch:
      operation: ADD
      value:
        name: ratelimit_cluster
        type: STRICT_DNS
        connect_timeout: 1s
        http2_protocol_options: {}
        lb_policy: ROUND_ROBIN
        load_assignment:
          cluster_name: ratelimit_cluster
          endpoints:
          - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: ratelimit.ratelimit.svc.cluster.local
                    port_value: 8081

  # ROUTE
  - applyTo: HTTP_ROUTE
    match:
      context: GATEWAY
    patch:
      operation: MERGE
      value:
        route:
          rate_limits:
          - actions:
            - generic_key:
                descriptor_value: customerpoint
EOF

echo "===== DONE ====="