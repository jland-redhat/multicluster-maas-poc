# Multi-Cluster MaaS PoC

Proof-of-concept for **shared API key storage** across three OpenShift clusters using **RHOAI 3.4** (operator-managed MaaS).

| Cluster | Role |
|---------|------|
| **hub** | PostgreSQL + key minting + same simulator models/subscriptions as clients |
| **client1**, **client2** | Inference + validation-only maas-api, shared hub DB, key-mgmt blocked |

**What this proves:** mint an API key on the hub → use it for inference on client clusters when subscription names match.

> **Demo only.** Ephemeral PostgreSQL, public Route, hardcoded demo password in manifests. Not for production.

See [SPEC.md](SPEC.md) for design decisions.

---

## Prerequisites

- Three blank OpenShift clusters (RHOAI 3.4 compatible — OCP 4.16+)
- `oc`, `helm`, `kustomize`, `jq`, `curl` on your workstation
- Cluster-admin on each cluster
- This repo checked out (scripts call `../scripts/setup-gateway.sh` in the parent maas-billing tree)
- Client clusters can reach the hub **postgres-hub** Route on port **443**

---

## Quick start (orchestrated)

```bash
cd multicluster-poc

# 1. Hub
export HUB_KUBECONFIG=/path/to/hub/kubeconfig
./scripts/install-hub.sh --kubeconfig "${HUB_KUBECONFIG}"

# 2. Client 1
export CLIENT1_KUBECONFIG=/path/to/client1/kubeconfig
./scripts/install-client.sh \
  --kubeconfig "${CLIENT1_KUBECONFIG}" \
  --hub-kubeconfig "${HUB_KUBECONFIG}" \
  --cluster client1

# 3. Client 2
export CLIENT2_KUBECONFIG=/path/to/client2/kubeconfig
./scripts/install-client.sh \
  --kubeconfig "${CLIENT2_KUBECONFIG}" \
  --hub-kubeconfig "${HUB_KUBECONFIG}" \
  --cluster client2

# 4. Validate
./scripts/validate-poc.sh \
  --hub-kubeconfig "${HUB_KUBECONFIG}" \
  --client-kubeconfig "${CLIENT1_KUBECONFIG}"
```

---

## Manual step-by-step

Run on each cluster unless noted.

### Phase 0 — All clusters

```bash
./scripts/install-rhoai.sh --kubeconfig "${KUBECONFIG}"
```

Optional GitOps (requires a git remote containing this folder):

```bash
./scripts/bootstrap-gitops.sh --cluster hub --kubeconfig "${KUBECONFIG}" \
  --git-repo https://github.com/YOUR_ORG/maas-billing
```

Without `--git-repo`, apply manifests directly with the scripts below.

### Phase 1 — Hub only

```bash
./scripts/install-rhcl.sh --kubeconfig "${HUB_KUBECONFIG}"
./scripts/apply-hub-postgres.sh --kubeconfig "${HUB_KUBECONFIG}"
./scripts/setup-gateway.sh --kubeconfig "${HUB_KUBECONFIG}"
./scripts/enable-maas.sh --kubeconfig "${HUB_KUBECONFIG}"
./scripts/apply-models.sh --kubeconfig "${HUB_KUBECONFIG}"
```

Argo CD Applications (`maas-poc-hub-postgres`, `maas-poc-models`) are created automatically
when using `install-hub.sh` or `bootstrap-gitops.sh` (default git repo is this project).

### Phase 2 — Each client

```bash
./scripts/setup-gateway.sh --kubeconfig "${CLIENT_KUBECONFIG}"
./scripts/sync-hub-db-to-clients.sh \
  --hub-kubeconfig "${HUB_KUBECONFIG}" \
  --client-kubeconfig "${CLIENT_KUBECONFIG}" \
  --test-connection
./scripts/enable-maas.sh --kubeconfig "${CLIENT_KUBECONFIG}"
./scripts/apply-models.sh --kubeconfig "${CLIENT_KUBECONFIG}"
./scripts/disable-key-management.sh --kubeconfig "${CLIENT_KUBECONFIG}"
```

### Phase 3 — Validate

```bash
./scripts/validate-poc.sh \
  --hub-kubeconfig "${HUB_KUBECONFIG}" \
  --client-kubeconfig "${CLIENT_KUBECONFIG}"
```

---

## Models and subscriptions

Identical on every client cluster (vendored from maas-billing samples):

| Sample | Model | Subscription | Group |
|--------|-------|--------------|-------|
| free | `facebook-opt-125m-simulated` | `simulator-subscription` | `system:authenticated` |
| premium | `premium-simulated-simulated-premium` | `premium-simulator-subscription` | `premium-user` |

Mint on the hub with explicit subscription:

```bash
export KUBECONFIG="${HUB_KUBECONFIG}"
HOST="maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
curl -skS -X POST \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"demo","subscription":"simulator-subscription","expiresIn":"2h"}' \
  "https://${HOST}/maas-api/v1/api-keys"
```

Gateway host: `maas.<cluster-ingress-domain>`.

---

## Layout

```
multicluster-poc/
├── helm/gitops-bootstrap/     # OpenShift GitOps operator + optional Argo Applications
├── kustomize/
│   ├── hub/postgres/          # Hub DB + Route
│   ├── client/models/         # Simulator bundles
│   └── client/disable-key-management/
├── samples/                   # Vendored model/MaaS YAML
└── scripts/                   # Install, sync, validate
```

---

## Hub PostgreSQL connectivity

- **In-cluster (hub maas-api):** `postgres.redhat-ods-applications.svc:5432`
- **Cross-cluster (clients):** `postgres-hub` Route hostname, port **443**, TCP passthrough, `sslmode=disable`
- Default demo password: `maas-poc-demo-change-me` (override in `kustomize/hub/postgres/postgres.yaml` before deploy)

---

## Client key-management lockdown

`disable-key-management.sh` applies an RHCL/Kuadrant `AuthPolicy` denying all `/maas-api/v1/api-keys*` paths on the gateway.

Blocked: mint, search, revoke, bulk-revoke, per-key CRUD.

Not blocked: `/maas-api/health`, `/v1/models`, internal Authorino validation to maas-api.

Re-run the script if the operator reconciles and removes the deny policy.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| maas-api CrashLoop | `maas-db-config` exists; client can reach hub Route:443 |
| Mint works on client | Re-run `disable-key-management.sh` |
| Inference 403 | Subscription name on key matches client `MaaSSubscription`; model Ready |
| Gateway not Programmed | Re-run `setup-gateway.sh`; check RHCL/Authorino in `rh-connectivity-link` |
| RHOAI not ready | `oc get dscinitialization,datasciencecluster` |

---

## GitOps note

Argo CD Applications in `helm/gitops-bootstrap` need `git.repoURL` pointing at a remote containing `multicluster-poc/`. Until you push this folder, use the direct `oc apply` scripts.

---

## Non-goals

Production database, Keycloak, cross-cluster gateway mesh, hub inference workloads.
