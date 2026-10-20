# Architecture Overview

## Purpose

This repo builds a **hub-and-spoke multi-cluster lab** entirely on one machine:

- `kind` provides the Kubernetes clusters, all attached to one Docker bridge
  network (`kubara-mesh`).
- **Cilium ClusterMesh** stitches the clusters into one addressing/identity
  mesh — the "hub" is cluster id 1 and every other cluster is a spoke.
- **Kubara** bootstraps the hub and generates the platform Helm values
  ("desired state" in git).
- **Argo CD** (self-managed on the hub) deploys the entire infrastructure
  stack from git `main` across all clusters.
- **OpenBao** (Vault fork) is the secret backing store: spoke kubeconfigs and
  platform credentials are published there and materialized into Kubernetes
  Secrets by External Secrets.
- Platform-engineering tools run on `kubara-spoke-1`; `dev` / `staging` /
  `prod` spokes consume them.

## Topology

Six kind clusters, one Docker network, one DNS zone:

| Cluster | Stage (`config.yaml`) | Cilium ID | Role |
| --- | --- | --- | --- |
| `hub` | `local` | 1 | Control plane + observability |
| `kubara-spoke-1` | `platform-engineering` | 2 | Platform tools |
| `kubara-spoke-2` | `poc` | 3 | POC / evaluation services |
| `kubara-dev` | `dev` | 4 | Workload target (dev) |
| `kubara-staging` | `staging` | 5 | Workload target (staging) |
| `kubara-prod` | `prod` | 6 | Workload target (prod) |

Cluster inventory is declared in `z-demo-setup/config/kind-demo.yaml` and the
per-cluster services/desired-state in `config.yaml`. The per-cluster kind
overlays are `z-demo-setup/config/kind-*-overlay.yaml` and
`kind-hub-cilium.yaml`.

## Control flow (top → bottom)

```
git main ──────────► Argo CD (hub) ──────────► spokes
                        │
                        ├─ materialized cluster secrets
                        │      (kubeconfigs published via OpenBao)
                        ▼
              platform tools on spoke-1
                        │
                        ▼
              dev / staging / prod workloads
                        ▲
                        │  (delivery via Forgejo → Harbor → Kargo → Argo CD)
                        └───────────────────────────┘
```

## What lives on which cluster

| Component | Hub | spoke-1 | spoke-2 | dev | staging | prod |
| --- | :-: | :-: | :-: | :-: | :-: | :-: |
| Argo CD | ✔ (self-managed) | managed | managed | managed | managed | managed |
| Traefik ingress | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| cert-manager | ✔ | ✔ | – | ✔ | ✔ | ✔ |
| External Secrets | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| OpenBao | ✔ | – | – | – | – | – |
| kube-prometheus-stack | ✔ | – | – | – | – | – |
| metrics-server | ✔ | – | – | – | – | – |
| Homer dashboard | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| Forgejo / Harbor / Kargo / Nexus | – | ✔ | – | – | – | – |
| Keycloak / OpenProject / Apicurio / OPA | – | ✔ | – | – | – | – |
| Kafka / Ollama / Uptime Kuma | – | – | ✔ | – | – | – |
| PostgreSQL (bitnami) | – | ✔ | ✔ | ✔ | ✔ | ✔ |
| PostgreSQL 19 (CloudNativePG) | – | – | ✔ | – | – | – |

## Bring-up pipeline

Orchestrated by `just bring-up` (root `Justfile`), which runs:

1. `z-demo-setup/scripts/build-mesh.sh` — create/rebuild clusters, install
   Cilium, enable ClusterMesh, connect hub ↔ each spoke, ensure
   cloud-provider-kind is running, bootstrap the hub (Kubara), publish spoke
   kubeconfigs to OpenBao, provision platform DBs.
2. Wait for all six traefik LoadBalancer IPs.
3. `just refresh-dns-lb-hosts` — rewrite the dnsmasq map from live LB IPs.

Because LB IPs are assigned dynamically by cloud-provider-kind, no address is
ever pinned in chart values; the only place that records live IPs is
`dnsmasq/config/dnsmasq.conf`.

## Key repo areas

| Path | Role |
| --- | --- |
| `config.yaml` | Kubara desired state: cluster stages + enabled services |
| `catalogs/` | Kubara catalog defs (`bootstrap`, `general`, `backing-services`, `platform-engineering`) |
| `platform-components/helm/` | Rendered/runtime Helm charts for every service |
| `platform-configs/<cluster>/helm/<svc>/` | Generated per-cluster values (incl. durable `values-additional`/`values-custom`) |
| `z-demo-setup/scripts/build-mesh.sh` | Cluster mesh build + hub bootstrap + secret publishing |
| `z-demo-setup/scripts/provision-platform.sh` | Idempotent secrets + PostgreSQL + Liquibase provisioning |
| `z-demo-setup/scripts/bootstrap-kubara-hub.sh` | Kubara hub bootstrap + *.kubara.test DNS re-pin |
| `dnsmasq/` | Host DNS: per-cluster wildcard → traefik LB IPs |
| `observability-design-options.md` | Earlier observability trade-off write-up |

## Related docs

- [Networking](./networking.md)
- [GitOps & Argo CD](./gitops-and-argocd.md)
- [Platform services](./platform-services.md)
- [Delivery pipelines](./pipelines.md)
- [Issues found](../issues.md)