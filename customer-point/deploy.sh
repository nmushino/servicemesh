#!/bin/bash
set -e

# ----------------------------
# Settings
# ----------------------------
APP_NAME=customer-point-api
PROJECT=demo
BASE_DIR=$(pwd)
DOCKER_CONTEXT_DIR=${BASE_DIR}/build
DOCKERFILE_SRC=${BASE_DIR}/src/main/docker/Dockerfile
QUARKUS_TARGET=${BASE_DIR}/target/quarkus-app

RATELIMIT_NS=ratelimit
REDIS_IMAGE=redis:7.0
RATELIMIT_IMAGE=envoyproxy/ratelimit:v1.4.0

ISTIO_NAMESPACE=istio-system

SLEEP_INTERVAL=10

# ----------------------------
echo "===== OpenShift Login ====="
oc whoami >/dev/null

echo "===== Use Project ====="
oc new-project ${PROJECT} || oc project ${PROJECT}

# ----------------------------
echo "===== Build the App ====="
mvn clean package -DskipTests

rm -rf ${DOCKER_CONTEXT_DIR}
mkdir -p ${DOCKER_CONTEXT_DIR}
cp ${DOCKERFILE_SRC} ${DOCKER_CONTEXT_DIR}/Dockerfile
cp entrypoint.sh ${DOCKER_CONTEXT_DIR}/entrypoint.sh
mkdir -p ${DOCKER_CONTEXT_DIR}/quarkus-app
cp -r ${QUARKUS_TARGET}/* ${DOCKER_CONTEXT_DIR}/quarkus-app/

oc delete bc ${APP_NAME} || true
oc delete is ${APP_NAME} || true
oc new-build --name=${APP_NAME} --binary --strategy=docker
oc start-build ${APP_NAME} --from-dir=${DOCKER_CONTEXT_DIR} --follow

IMAGE_NAME=$(oc get istag ${APP_NAME}:latest -o jsonpath='{.image.dockerImageReference}')

echo "===== Install Istio ====="
oc adm policy add-scc-to-user anyuid -z istio-egressgateway-service-account -n ${ISTIO_NAMESPACE} || true
oc adm policy add-scc-to-user anyuid -z istio-ingressgateway-service-account -n ${ISTIO_NAMESPACE} || true

if oc get deployment istiod -n ${ISTIO_NAMESPACE} >/dev/null 2>&1; then
  echo "Istio already installed, skipping istioctl install"
else
  echo "Installing Istio..."
  istioctl install --set profile=demo -y
fi

echo "===== Wait Istio ====="
oc wait --for=condition=available deployment/istiod -n ${ISTIO_NAMESPACE} --timeout=300s
oc wait --for=condition=available deployment/istio-egressgateway -n ${ISTIO_NAMESPACE} --timeout=300s
oc wait --for=condition=available deployment/istio-ingressgateway -n ${ISTIO_NAMESPACE} --timeout=300s

# ----------------------------
echo "===== Deploy App ====="
oc delete deployment ${APP_NAME} -n ${PROJECT} || true
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
EOF

echo "===== Create Service ====="
oc expose deployment ${APP_NAME} --port=8080 -n ${PROJECT} || true

# ----------------------------
echo "===== Apply RateLimit ====="
oc create namespace ${RATELIMIT_NS} || true

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
      value: customerpoint
      rate_limit:
        unit: minute
        requests_per_unit: 10
EOF

# Redis
oc apply -n ${RATELIMIT_NS} -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
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
EOF

# RateLimit Service
cat <<EOF | oc apply -n ${RATELIMIT_NS} -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ratelimit
spec:
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
        command: ["/bin/ratelimit"]
        env:
        - name: LOG_LEVEL
          value: debug
        - name: REDIS_SOCKET_TYPE
          value: tcp
        - name: REDIS_URL
          value: redis:6379
        - name: RUNTIME_ROOT
          value: /data
        - name: RUNTIME_SUBDIRECTORY
          value: config
        volumeMounts:
        - name: config
          mountPath: /data/config/config.yaml
          subPath: config.yaml
      volumes:
      - name: config
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
  - name: grpc
    port: 8081
    targetPort: 8081
EOF

# ----------------------------
echo "===== Configure Gateway API ====="
cat <<EOF | oc apply -n ${ISTIO_NAMESPACE} -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external-gateway
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            kubernetes.io/metadata.name: demo
EOF

cat <<EOF | oc apply -n ${PROJECT} -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: customer-point
spec:
  parentRefs:
  - name: external-gateway
    namespace: ${ISTIO_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /customerpoint
    backendRefs:
    - name: customer-point-api
      port: 8080
EOF

# ----------------------------
echo "===== Apply EnvoyFilter ====="
cat <<EOF | oc apply -n ${ISTIO_NAMESPACE} -f -
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: ratelimit-filter
  namespace: istio-system

spec:
  workloadSelector:
    labels:
      istio: ingressgateway

  configPatches:

  # RateLimit Filter
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
                cluster_name: outbound|8081||ratelimit.ratelimit.svc.cluster.local

  # Route/VHost RateLimit
  - applyTo: VIRTUAL_HOST

    match:
      context: GATEWAY

      routeConfiguration:
        vhost:
          name: "*:80"

    patch:
      operation: MERGE

      value:
        rate_limits:
        - actions:
          - generic_key:
              descriptor_value: customerpoint
EOF

# ----------------------------
echo "===== Expose Ingress ====="
oc expose svc/istio-ingressgateway -n ${ISTIO_NAMESPACE} || true

echo "===== DONE ====="