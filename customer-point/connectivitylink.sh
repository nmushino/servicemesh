#!/bin/bash
set -e

PROJECT=connectivity-link
ISTIO_NAMESPACE=istio-system
DEMO_NS=demo
SLEEP_INTERVAL=10

echo "===== Create Project ====="
oc new-project ${ISTIO_NAMESPACE} 2>/dev/null || oc project ${ISTIO_NAMESPACE}

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

echo "===== Create Project ====="
oc new-project ${PROJECT} 2>/dev/null || oc project ${PROJECT}

echo "===== Install Connectivity Link Operator ====="
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: connectivity-link-group
  namespace: ${PROJECT}
spec:
  features:
    auth:
      enabled: true
    rateLimit:
      enabled: true
    dns:
      enabled: false
  devportal:
    enabled: true
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhcl-operator
  namespace: ${PROJECT}
spec:
  channel: stable
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

echo "===== Install Kuadrant ====="
cat <<EOF | oc apply -f -
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: ${PROJECT}
spec:
  devportal:
    enabled: true
  features:
    rateLimit: true
    auth: true
EOF

echo "===== Create Gateway (Gateway API) ====="
cat <<EOF | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: connectivity-link-gateway
  namespace: ${PROJECT}
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
EOF

echo "===== Create ReferenceGrant ====="
cat <<EOF | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-connectivity-link
  namespace: demo
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: ${PROJECT}
  to:
  - group: ""
    kind: Service
EOF

echo "===== Create demo namespace ====="
oc new-project ${DEMO_NS} 2>/dev/null || true

cat <<EOF | oc apply -n ${DEMO_NS} -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: customer-point-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: customer-point-api
  template:
    metadata:
      labels:
        app: customer-point-api
    spec:
      containers:
      - name: api
        image: image-registry.openshift-image-registry.svc:5000/demo/customer-point-api:latest
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: customer-point-api
spec:
  selector:
    app: customer-point-api
  ports:
  - port: 8080
    targetPort: 8080
EOF

echo "===== Create HTTPRoute ====="
cat <<EOF | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: customerpoint-route
  namespace: ${PROJECT}
spec:
  parentRefs:
  - name: connectivity-link-gateway
    namespace: ${PROJECT}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /customerpoint
    backendRefs:
    - name: customer-point-api
      namespace: ${DEMO_NS}
      port: 8080
EOF

echo "===== Create APIKey ====="
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: demo-apikey
  namespace: ${PROJECT}
  labels:
    kuadrant.io/apikey: demo-apikey
stringData:
  api_key: my-secret-key
type: Opaque
---
# Developer Portal のために利用するので一旦無効化
# apiVersion: devportal.kuadrant.io/v1alpha1
# kind: APIProduct
# metadata:
#   name: demo-api-product
#   namespace: ${PROJECT}
# spec:
#   displayName: "Demo API Product"
#   publishStatus: Published
#   approvalMode: automatic
#   targetRef:
#     group: gateway.networking.k8s.io
#     kind: HTTPRoute
#     name: customerpoint-route
#     namespace: ${PROJECT}
#   apiKeys:
#     - name: demo-apikey
# ---
# apiVersion: devportal.kuadrant.io/v1alpha1
# kind: APIKey
# metadata:
#   name: demo-apikey
#   namespace: ${PROJECT}
# spec:
#   value: my-secret-key
#   apiProductRef:
#     name: demo-api-product
#     namespace: ${PROJECT}
#   planTier: STANDARD
#   requestedBy:
#     userId: nmushino
#     email: nmushino@redhat.com
#   useCase: "Demo testing"
---
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: demo-authpolicy
  namespace: ${PROJECT}
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: customerpoint-route
  defaults:
    strategy: merge
    rules:
      authentication:
        api-key-authn:
          apiKey:
            allNamespaces: true
            selector:
              matchLabels:
                kuadrant.io/apikey: demo-apikey
          credentials:
            authorizationHeader:
              prefix: Bearer
    response:
      success:
        filters:
          identity:
            json:
              properties:
                apikey:
                  selector: auth.identity.value
EOF

# echo "===== API Publish ====="
# oc patch apiproduct demo-api-product \
#   -n connectivity-link \
#   --type merge \
#   -p '{"spec":{"publishStatus":"Published"}}'


echo "===== Expose Kiali/Grafana/Prometheus via Istio Addons ====="
oc apply -f https://raw.githubusercontent.com/istio/istio/release-1.29/samples/addons/prometheus.yaml
oc apply -f https://raw.githubusercontent.com/istio/istio/release-1.29/samples/addons/grafana.yaml
oc apply -f https://raw.githubusercontent.com/istio/istio/release-1.29/samples/addons/kiali.yaml

for addon in kiali grafana prometheus; do
  echo "Waiting for ${addon} pod to appear..."
  SECONDS_WAITED=0
  while ! oc get pod -l app.kubernetes.io/name=${addon} -n ${ISTIO_NAMESPACE} >/dev/null 2>&1; do
    echo "  ${addon} pod not found yet... ($SECONDS_WAITED sec)"
    sleep $SLEEP_INTERVAL
    SECONDS_WAITED=$((SECONDS_WAITED + SLEEP_INTERVAL))
    if [ $SECONDS_WAITED -ge 600 ]; then
      echo "Timeout waiting for ${addon} pod"
      break
    fi
  done
  if oc get pod -l app.kubernetes.io/name=${addon} -n ${ISTIO_NAMESPACE} >/dev/null 2>&1; then
    echo "Waiting for ${addon} pod to be ready..."
    oc wait --for=condition=ready pod -l app.kubernetes.io/name=${addon} -n ${ISTIO_NAMESPACE} --timeout=300s
  fi
  # Route 作成
  if ! oc get route ${addon} -n ${ISTIO_NAMESPACE} >/dev/null 2>&1; then
    oc expose svc ${addon} -n ${ISTIO_NAMESPACE}
  fi
done

GATEWAY_HOST=$(oc get svc connectivity-link-gateway-istio -n ${PROJECT} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
KIALI_URL=$(oc get route kiali -n ${ISTIO_NAMESPACE} -o jsonpath='{.spec.host}')
GRAFANA_URL=$(oc get route grafana -n ${ISTIO_NAMESPACE} -o jsonpath='{.spec.host}')
PROM_URL=$(oc get route prometheus -n ${ISTIO_NAMESPACE} -o jsonpath='{.spec.host}')

echo ""
echo "===== DONE ====="
echo ""
echo "Access Connectivity Link Demo URL via ELB:"
echo "http://${GATEWAY_HOST}/customerpoint"
echo ""
echo "Istio Addons Web UI Routes:"
echo "Kiali     : http://${KIALI_URL}"
echo "Grafana   : http://${GRAFANA_URL}"
echo "Prometheus: http://${PROM_URL}"
echo ""
echo "Check pods:"
echo "oc get pods -n ${PROJECT}"
echo "oc get pods -n ${ISTIO_NAMESPACE}   # Kiali/Grafana/Prometheus"
