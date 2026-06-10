# Multi-Cluster MaaS PoC — Build Spec

## Purpose

Demonstrate **shared API key storage** across OpenShift clusters:

- **Hub** — PostgreSQL + key minting only (no models).
- **Client 1 & Client 2** — full inference stack, two simulator models each, maas-api with shared hub DB for API key validation.

**Success criteria:** mint a key on the hub → use it for inference on both clients, assuming **identical subscription names** on every cluster.

---

## Constraints

| Topic | Decision |
|-------|----------|
| Platform | **RHOAI 3.4** — MaaS via operator (`modelsAsService: Managed`), **not** maas-billing Kustomize overlays |
| Hub role | DB + minting only — **no models** |
| DB exposure | Public OpenShift Route from hub (TCP passthrough — simplest for demo) |
| Postgres durability | Ephemeral (`emptyDir`) — demo only |
| Git hosting | Local folder in this repo for now |
| Templating | **Helm** for GitOps bootstrap + Postgres; **Kustomize** for models, policies, Argo apps |
| Identity | OpenShift `kubernetesTokenReview` only — no Keycloak |
| Subscriptions | **Same names on every cluster** (`simulator-subscription`, `premium-simulator-subscription`) |
| Starting point | **Three blank clusters** — README defines install order |
| Cluster names | `hub`, `client1`, `client2` |

---

## Folder layout

```
multicluster-poc/
├── README.md
├── SPEC.md
├── helm/
│   ├── gitops-bootstrap/
│   └── hub-postgres/
├── kustomize/
│   ├── hub/
│   │   ├── postgres/
│   │   └── argocd-apps/
│   ├── client/
│   │   └── argocd-apps/
│   └── common/
│       └── datasciencecluster.yaml
├── samples/
│   ├── free/
│   └── premium/
└── scripts/
    ├── install-rhoai.sh
    ├── setup-gateway.sh
    ├── enable-maas.sh
    ├── apply-hub-postgres.sh
    ├── apply-client-models.sh
    ├── bootstrap-gitops.sh
    ├── sync-hub-db-to-clients.sh
    ├── validate-poc.sh
    ├── install-hub.sh
    └── install-client.sh
```

---

## What each cluster runs

### All clusters (hub + clients)

1. **RHOAI 3.4 operator** — `rhods-operator`, channel `stable-3.x`, apps namespace `redhat-ods-applications`.
2. **Red Hat Connectivity Link (RHCL)** — installed by RHOAI; Authorino in `rh-connectivity-link`.
3. **`maas-default-gateway`** — create **before** enabling `modelsAsService`.
4. **`maas-db-config` Secret** — key `DB_CONNECTION_URL` in `redhat-ods-applications`.
5. **DataScienceCluster v2** with `modelsAsService: Managed`.
6. **OpenShift GitOps** — Helm bootstrap + Argo CD Applications.

### Hub only

- Ephemeral PostgreSQL + TCP passthrough Route.
- In-cluster `maas-db-config` URL.
- No models. Minting enabled.

### Clients only

- Two simulator models (`free` + `premium` samples).
- `maas-db-config` → hub Route URL (sync script).
- Key management blocked on gateway paths.

---

## Install order

See [README.md](README.md) for the full runbook.

---

## Validation

1. Hub: mint key with OpenShift token + subscription name.
2. Clients: inference with hub-minted key succeeds.
3. Clients: all `/maas-api/v1/api-keys*` endpoints denied.
4. Optional: revoke on hub → inference fails on clients.

---

## Non-goals

- Production Postgres, Keycloak, cross-cluster gateway/mesh, hub inference, separate git remote.
