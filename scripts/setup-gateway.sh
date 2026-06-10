#!/usr/bin/env bash
# Create maas-default-gateway for Models-as-a-Service (route mode).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KUBECONFIG_PATH=""
INGRESS_MODE="${INGRESS_MODE:-route}"

usage() {
  cat <<'EOF'
Usage: setup-gateway.sh [--kubeconfig PATH]

Creates maas-default-gateway in openshift-ingress (route mode, default for ROSA/OSD).
Bootstraps Authorino TLS for RHCL when Authorino is present.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

setup_kubeconfig "${KUBECONFIG_PATH}"

if [[ "${INGRESS_MODE}" != "route" ]]; then
  die "only INGRESS_MODE=route is supported in this PoC (got: ${INGRESS_MODE})"
fi

require_cmd envsubst

ensure_gatewayclass() {
  if ! oc get gatewayclass openshift-default >/dev/null 2>&1; then
    log "Creating GatewayClass openshift-default..."
    oc apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: openshift.io/gateway-controller/v1
EOF
  fi

  log "Waiting for GatewayClass openshift-default to be accepted..."
  local deadline=$((SECONDS + 300))
  while true; do
    local accepted
    accepted="$(oc get gatewayclass openshift-default \
      -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
    if [[ "${accepted}" == "True" ]]; then
      log "GatewayClass openshift-default is Accepted"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      warn "GatewayClass openshift-default not Accepted after 300s — gateway controller may still be starting; continuing"
      return 0
    fi
    sleep 5
  done
}

detect_cluster_domain() {
  local domain
  domain="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  [[ -n "${domain}" ]] || die "could not detect cluster domain (set CLUSTER_DOMAIN)"
  printf '%s' "${domain}"
}

detect_tls_certificate() {
  local ns="${GATEWAY_NAMESPACE}" cert=""

  cert="$(oc get ingresscontroller default -n openshift-ingress-operator \
    -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null || true)"
  if [[ -n "${cert}" ]] && oc get secret "${cert}" -n "${ns}" >/dev/null 2>&1; then
    printf '%s' "${cert}"
    return 0
  fi

  for cert in default-gateway-cert router-certs-default; do
    if oc get secret "${cert}" -n "${ns}" >/dev/null 2>&1; then
      printf '%s' "${cert}"
      return 0
    fi
  done

  die "no TLS certificate secret found in ${ns} — set CERT_NAME or create router-certs-default"
}

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(detect_cluster_domain)}"
CERT_NAME="${CERT_NAME:-$(detect_tls_certificate)}"

ensure_gatewayclass

log "Creating maas-default-gateway (hostname=maas.${CLUSTER_DOMAIN}, cert=${CERT_NAME})..."
export CLUSTER_DOMAIN CERT_NAME
envsubst '$CLUSTER_DOMAIN $CERT_NAME' <<'EOF' | oc apply --server-side=true -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: maas-default-gateway
  namespace: openshift-ingress
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
  labels:
    app.kubernetes.io/name: maas
    app.kubernetes.io/instance: maas-default-gateway
    app.kubernetes.io/component: gateway
    opendatahub.io/managed: "false"
spec:
  gatewayClassName: openshift-default
  listeners:
    - name: http
      hostname: maas.${CLUSTER_DOMAIN}
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      hostname: maas.${CLUSTER_DOMAIN}
      port: 443
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: All
      tls:
        certificateRefs:
          - group: ""
            kind: Secret
            name: ${CERT_NAME}
        mode: Terminate
EOF

if ! oc wait --for=condition=Programmed \
  gateway/maas-default-gateway -n "${GATEWAY_NAMESPACE}" --timeout=120s 2>/dev/null; then
  warn "maas-default-gateway not Programmed yet — check GatewayClass and RHCL; re-run if needed"
else
  log "maas-default-gateway is Programmed"
fi

if oc get deployment authorino -n "${AUTHORINO_NAMESPACE}" >/dev/null 2>&1; then
  authorino_ns="${AUTHORINO_NAMESPACE}"
elif oc get deployment authorino -n rh-connectivity-link >/dev/null 2>&1; then
  authorino_ns="rh-connectivity-link"
else
  authorino_ns=""
fi

if [[ -n "${authorino_ns}" ]]; then
  log "Bootstrapping Authorino TLS for RHCL (namespace=${authorino_ns})..."
  oc annotate service authorino-authorino-authorization \
    -n "${authorino_ns}" \
    service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
    --overwrite
  oc patch authorino authorino -n "${authorino_ns}" --type=merge --patch '
{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": {
          "name": "authorino-server-cert"
        }
      }
    }
  }
}'
  oc -n "${authorino_ns}" set env deployment/authorino \
    SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
else
  warn "Authorino not found in ${AUTHORINO_NAMESPACE} or rh-connectivity-link — skip TLS bootstrap (run install-rhcl.sh first)"
fi

log "Gateway setup complete."
