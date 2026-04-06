#!/bin/bash
set -e

# ----------------------------
# 設定
# ----------------------------
APP_NAME=customer-point-api
PROJECT=demo
BASE_DIR=$(pwd)
DOCKER_CONTEXT_DIR=${BASE_DIR}/build
DOCKERFILE_SRC=${BASE_DIR}/src/main/docker/Dockerfile
COBOL_SRC=${BASE_DIR}/cobol-resources/customer-point.cbl
QUARKUS_TARGET=${BASE_DIR}/target/quarkus-app

# RateLimit用
RATELIMIT_NS=ratelimit
REDIS_IMAGE=redis:7.0
RATELIMIT_IMAGE=envoyproxy/ratelimit:v1.4.0

ISTIO_NAMESPACE=istio-system

# ----------------------------
# OpenShift Login / Project
# ----------------------------
echo "===== OpenShift Login Check ====="
oc whoami

echo "===== Use Project ====="
oc new-project ${PROJECT} || oc project ${PROJECT}

# Ambient Mesh ラベル設定
oc label namespace ${PROJECT} istio.io/dataplane-mode=ambient --overwrite

# ----------------------------
# Build
# ----------------------------
echo "===== Delete old BuildConfig and ImageStream ====="
oc delete bc ${APP_NAME} || true
oc delete is ${APP_NAME} || true

echo "===== Build Quarkus App ====="
mvn clean package -DskipTests

echo "===== Prepare build context ====="
rm -rf ${DOCKER_CONTEXT_DIR}
mkdir -p ${DOCKER_CONTEXT_DIR}

cp ${DOCKERFILE_SRC} ${DOCKER_CONTEXT_DIR}/Dockerfile
cp ${COBOL_SRC} ${DOCKER_CONTEXT_DIR}/customer-point.cbl
cp entrypoint.sh ${DOCKER_CONTEXT_DIR}/entrypoint.sh

if [ -d "${QUARKUS_TARGET}" ]; then
    mkdir -p ${DOCKER_CONTEXT_DIR}/quarkus-app
    cp -r ${QUARKUS_TARGET}/* ${DOCKER_CONTEXT_DIR}/quarkus-app/
fi

echo "===== Create BuildConfig ====="
oc new-build --name=${APP_NAME} --binary --strategy=docker

echo "===== Start Binary Build ====="
oc start-build ${APP_NAME} --from-dir=${DOCKER_CONTEXT_DIR} --follow

# ----------------------------
# Deploy Application
# ----------------------------
echo "===== Deploy Application ====="
IMAGE_NAME=$(oc get istag ${APP_NAME}:latest -o jsonpath='{.image.dockerImageReference}')

oc delete deployment ${APP_NAME} || true

cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}
      deployment: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
        deployment: ${APP_NAME}
    spec:
      containers:
      - name: ${APP_NAME}
        image: ${IMAGE_NAME}
        ports:
        - containerPort: 8080
EOF

echo "===== List Pods ====="
oc get pods

# Service作成
if oc get svc ${APP_NAME} >/dev/null 2>&1; then
    oc patch svc ${APP_NAME} -p '{"spec":{"selector":{"app":"'"${APP_NAME}"'","deployment":"'"${APP_NAME}"'"}}}'
else
    oc expose deployment ${APP_NAME} --port=8080
fi
oc expose svc/${APP_NAME} || true

# ----------------------------
# RateLimit + Redis 設定
# ----------------------------
echo "===== Apply RateLimit Components ====="

oc create namespace ${RATELIMIT_NS} || echo "Namespace ${RATELIMIT_NS} already exists"

# ConfigMap
cat <<EOF | oc apply -n ${RATELIMIT_NS} -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ratelimit-config
data:
  config.yaml: |
    domain: customerpoint
    descriptors:
      - key: generic_key
        value: default
        rate_limit:
          unit: minute
          requests_per_unit: 10
EOF

# Redis Deployment + Service
cat <<EOF | oc apply -n ${RATELIMIT_NS} -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
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
spec:
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6379
EOF

# RateLimit Deployment + Service
oc -n ${RATELIMIT_NS} delete deployment ratelimit --ignore-not-found

cat <<EOF | oc apply -n ${RATELIMIT_NS} -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ratelimit
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
      initContainers:
      - name: wait-for-redis
        image: busybox
        command:
        - sh
        - -c
        - |
          echo "Waiting for Redis..."
          for i in \$(seq 1 30); do
            nc -z redis 6379 && break
            sleep 2
          done
          if ! nc -z redis 6379; then
            echo "Redis not available"
            exit 1
          fi
          echo "Redis is up!"
      containers:
      - name: ratelimit
        image: ${RATELIMIT_IMAGE}
        command: ["/bin/ratelimit"]
        env:
          - name: RUNTIME_ROOT
            value: /data/config
          - name: RUNTIME_SUBDIRECTORY
            value: config
          - name: REDIS_URL
            value: "redis:6379"
        volumeMounts:
          - name: ratelimit-config
            mountPath: /data/config/config/config.yaml
            subPath: config.yaml
        livenessProbe:
          httpGet:
            path: /healthcheck
            port: 8080
          initialDelaySeconds: 15
        readinessProbe:
          httpGet:
            path: /healthcheck
            port: 8080
          initialDelaySeconds: 10
      volumes:
        - name: ratelimit-config
          configMap:
            name: ratelimit-config
---
apiVersion: v1
kind: Service
metadata:
  name: ratelimit
spec:
  selector:
    app: ratelimit
  ports:
    - port: 8081
      targetPort: 8081
EOF

# EnvoyFilter
# ----------------------------
# EnvoyFilter（Gateway向け）適用
# ----------------------------
echo "===== Apply EnvoyFilter for Gateway (RateLimit) ====="

cat <<EOF | oc apply -n ${PROJECT} -f -
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: ratelimit-gateway
  namespace: ${PROJECT}
spec:
  workloadSelector:
    labels:
      istio.io/gateway-name: waypoint
  configPatches:
    - applyTo: VIRTUAL_HOST
      match:
        context: GATEWAY
      patch:
        operation: MERGE
        value:
          rate_limits:
            - actions:
                - generic_key:
                    descriptor_value: default
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
            failure_mode_deny: true
            rate_limit_service:
              grpc_service:
                envoy_grpc:
                  cluster_name: ratelimit_cluster
                timeout: 0.25s
EOF

# Waypoint Gateway
cat <<EOF | oc apply -n ${PROJECT} -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: demo
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
EOF
kubectl label namespace ${PROJECT} istio.io/use-waypoint=waypoint --overwrite

echo "===== DONE: RateLimit + Redis + EnvoyFilter + Waypoint applied ====="