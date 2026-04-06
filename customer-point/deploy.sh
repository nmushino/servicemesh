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
COBOL_SRC=${BASE_DIR}/cobol-resources/customer-point.cbl
QUARKUS_TARGET=${BASE_DIR}/target/quarkus-app

RATELIMIT_NS=ratelimit
REDIS_IMAGE=redis:7.0
RATELIMIT_IMAGE=envoyproxy/ratelimit:latest

ISTIO_NAMESPACE=istio-system

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
cp ${COBOL_SRC} ${DOCKER_CONTEXT_DIR}/customer-point.cbl
cp entrypoint.sh ${DOCKER_CONTEXT_DIR}/entrypoint.sh
mkdir -p ${DOCKER_CONTEXT_DIR}/quarkus-app
cp -r ${QUARKUS_TARGET}/* ${DOCKER_CONTEXT_DIR}/quarkus-app/

oc delete bc ${APP_NAME} || true
oc delete is ${APP_NAME} || true
oc new-build --name=${APP_NAME} --binary --strategy=docker
oc start-build ${APP_NAME} --from-dir=${DOCKER_CONTEXT_DIR} --follow

IMAGE_NAME=$(oc get istag ${APP_NAME}:latest -o jsonpath='{.image.dockerImageReference}')

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
    - key: PATH
      value: "/customerpoint"
      rate_limit:
        unit: minute
        requests_per_unit: 10
EOF

# Redis + RLS
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
        - name: RUNTIME_ROOT
          value: /data
        - name: RUNTIME_SUBDIRECTORY
          value: config
        - name: REDIS_URL
          value: redis:6379
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
echo "===== Enable Istio Ambient ====="
cat <<EOF | oc apply -n ${ISTIO_NAMESPACE} -f -
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: ambient-mesh
spec:
  namespace: ${ISTIO_NAMESPACE}
  profile: openshift-ambient
  version: v1.28.5
  components:
    ingressGateways:
    - name: istio-ingressgateway
      enabled: true
EOF

echo "Waiting for ingressgateway..."
until oc get svc istio-ingressgateway -n ${ISTIO_NAMESPACE} >/dev/null 2>&1; do sleep 5; done

# ----------------------------
echo "===== Configure Gateway API ====="
cat <<EOF | oc apply -n istio-system -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external-gateway
  namespace: istio-system
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostnames:
    - "*"
    allowedRoutes:
      namespaces:
        from: All
EOF

cat <<EOF | oc apply -n ${PROJECT} -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: customer-point
  namespace: demo
spec:
  parentRefs:
  - name: external-gateway
    namespace: istio-system
    port: 80   # listener の port を明示
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /customerpoint
    backendRefs:
    - name: customer-point-api
      port: 8080
EOF

cat <<EOF | oc apply -n ${PROJECT} -f -
apiVersion: v1
kind: Service
metadata:
  name: customer-point-api
  namespace: demo
spec:
  selector:
    app: customer-point-api
  ports:
  - port: 8080
    targetPort: 8080
EOF



# ----------------------------
echo "===== Apply Global RateLimit EnvoyFilter ====="
cat <<EOF | oc apply -n ${ISTIO_NAMESPACE} -f -
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: global-ratelimit
  namespace: istio-system
spec:
  workloadSelector:
    labels:
      istio: ingressgateway

  priority: 10   # ← 🔥超重要

  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: GATEWAY
    patch:
      operation: INSERT_FIRST   # ← 🔥これに変更
      value:
        name: envoy.filters.http.ratelimit
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.http.ratelimit.v3.RateLimit
          domain: customerpoint
          failure_mode_deny: true
          timeout: 5s
          rate_limit_service:
            grpc_service:
              envoy_grpc:
                cluster_name: outbound|8081||ratelimit.ratelimit.svc.cluster.local
            transport_api_version: V3
EOF

# ----------------------------
echo "===== Expose Ingress ====="
oc expose svc/istio-ingressgateway -n ${ISTIO_NAMESPACE} || true

echo "===== DONE ====="