# Observability Design Options for the Hub-and-Spoke Demo

The demo runs three kind clusters on one Docker network (`kubara-mesh`):

- `kind-hub` – control plane for ArgoCD, hosts `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager)
- `kind-kubara-spoke-1` – worker cluster (Forgejo, PostgreSQL, traefik, ...)
- `kind-kubara-spoke-2` – worker cluster

Prometheus and the Prometheus Operator CRDs exist **only on the hub**. Each spoke
runs Cilium with its own agent/operator, plus Hubble (Cilium's network observability
layer). Cilium pods run with `hostNetwork`, so their metrics endpoints are reachable
on the control-plane node IPs without any load balancer.

This document records the design options considered for shipping spoke metrics to
the hub Prometheus, and which one was implemented.

---

## Current state

All three clusters expose the same Cilium metrics endpoints (enabled via
`--set prometheus.enabled=true --set "hubble.metrics.enabled={dns,drop,tcp,flow,http,icmp}"`):

| Endpoint                 | Port | Scraped from              |
|--------------------------|-----:|---------------------------|
| cilium-agent             | 9962 | hostNetwork, node IP      |
| cilium-operator          | 9963 | hostNetwork, node IP       |
| hubble-metrics           | 9965 | hostNetwork, node IP      |

On the hub, three native Cilium ServiceMonitors (`cilium-agent`, `cilium-operator`,
`hubble`) are selected by the hub Prometheus (`monitoring.instance: hub-local` label)
and are scraped in-cluster.

---

## Option 1: Prometheus `remote_write` on each spoke (push)

Each spoke runs its own lightweight Prometheus (or thanos-sidecar) that writes
metrics to the hub collectors via `remote_write`.

```
   spoke-1                    spoke-2                      hub
┌──────────────┐          ┌──────────────┐          ┌───────────────────┐
│ cilium-agent │──┐       │ cilium-agent │──┐       │ Prometheus        │
│ hubble       │  │       │ hubble       │  │       │  remote_write API │
│ operator     │  │       │ operator     │  │       │  └─ receivers     │
└──────────────┘  │       └──────────────┘  │       └───────────────────┘
                  │       metrics (push)     │             ▲
                  └────────local───────┐     │      metric│ replicated
                     spoke Prometheus  └─────┼─────────────┘
                                          push│
```

Pros:
- Standard Prometheus feature; supports HA/victimless alignment.
- No inbound connections to spokes required.

Cons:
- Needs a receiver/collector on the hub (Prometheus alone has no remote-write
  receiver in the default distribution; typically requires Grafana Mimir or
  VictoriaMetrics, or a Prometheus + Thanos Receiver sidecar).
- Every spoke becomes a stateful metrics stack (TSDB, retention, alerts to wire).
- Overkill for a local demo.

Status: documented, **not selected**.

---

## Option 2: Cilium metrics + cross-cluster scraping (pull) - IMPLEMENTED

Cilium metrics are already TCP-reachable across the `kubara-mesh` Docker network,
so the hub Prometheus simply scrapes the spoke node IPs via `additionalScrapeConfigs`
(statically listed) while everything on the hub is picked up by the native
Cilium ServiceMonitors.

```
                               ┌──────────────────────────────┐
                               │            kind-hub          │
                               │  ┌────────────────────────┐  │
                               │  │ kube-prometheus-stack  │  │
                               │  │ Prometheus             │  │
                               │  │                       └──┼──────┐
                               │  └────────────────────────┘  │      │
                               └───────────────▲──────────────┘      │
                                             pull │  (scrape)
                   172.19.0.2  (hub node)       │
        ┌──────────────────┐     ┌──────────────┼──────────────┐
        │ kubara-mesh      │     │              ▼              │
        │ 172.19.0.0/16    │     │   ┌──────────────────────┐  │
        └──────────────────┘     │   │  kind-kubara-spoke-1 │  │
                                 │   │  172.19.0.3          │  │
                                 │   │  cilium-agent  9962  │◄─┘
                                 │   │  cilium-operator 9963│
                                 │   │  hubble-metrics 9965 │
                                 │   └──────────────────────┘
                                 │   ┌──────────────────────┐
                                 │   │  kind-kubara-spoke-2 │
                                 │   │  172.19.0.4          │
                                 │   │  cilium-agent  9962  │
                                 │   │  cilium-operator 9963│
                                 │   │  hubble-metrics 9965 │
                                 │   └──────────────────────┘
                                 └──────────────────────────────┘
```

Pros:
- No extra components; reuses the hub Prometheus already deployed.
- No state/data duplicated on spokes.
- Works with the shared Docker network (no LB or Ingress needed).

Cons:
- The spoke node IPs (`172.19.0.3`, `172.19.0.4`) are static but change if the
  kind cluster is rebuilt; the `additionalScrapeConfigs` must be refreshed.
- Scrape is pull-only; spoke-side time-series are not retained.

Status: **selected and implemented** (see "What was done" below).

---

## Option 3: Thanos (global query + HA store) 

Hub Prometheus stores locally; each spoke optionally runs a Thanos sidecar whose
TSDB is queried through a shared Thanos Querier (`--store` fan-out).

```
   spoke-1             spoke-2                hub
┌────────────┐      ┌────────────┐     ┌────────────────────┐
│ Prometheus │      │ Prometheus │     │ Prometheus (hub)   │
│ └ thanos   │      │ └ thanos   │     │                    │
│    sidecar │      │    sidecar │────►│ Thanos Querier     │──► Grafana
└────────────┘      └────────────┘     └────────────────────┘
```

Pros:
- Global view across clusters; can also add object storage for long-term retention.
- Full-featured HA: query, compaction, downsampling.

Cons:
- Highest complexity of the three: more components, sidecars, `--store` endpoints,
  and storage wiring.
- Requires exposing spoke store API endpoints inbound to the hub.

Status: documented, **not selected**.

---

## What was done (Option 2 implementation)

1. `z-demo-setup/scripts/build-mesh.sh` now passes, for every cluster:
   ```bash
   --set "prometheus.enabled=true"
   --set "hubble.metrics.enabled={dns,drop,tcp,flow,http,icmp}"
   ```
   and for the hub only also enables the native ServiceMonitors:
   ```bash
   --set "prometheus.serviceMonitor.enabled=true"
   --set "prometheus.serviceMonitor.trustCRDsExist=true"
   --set "prometheus.serviceMonitor.labels.monitoring\.instance=hub-local"
   --set "hubble.metrics.serviceMonitor.enabled=true"
   --set "hubble.metrics.serviceMonitor.trustCRDsExist=true"
   --set "hubble.metrics.serviceMonitor.labels.monitoring\.instance=hub-local"
   --set "operator.prometheus.enabled=true"
   --set "operator.prometheus.serviceMonitor.enabled=true"
   --set "operator.prometheus.serviceMonitor.trustCRDsExist=true"
   --set "operator.prometheus.serviceMonitor.labels.monitoring\.instance=hub-local"
   ```

2. `z-demo-setup/config/cilium/values.yaml` mirrors the same settings.

3. On the live clusters the changes were applied with `helm upgrade ... --reuse-values`
   for each context (`kind-hub`, `kind-kubara-spoke-1`, `kind-kubara-spoke-2`).

4. The hub Prometheus now has three in-cluster targets from the Cilium
   ServiceMonitors (agent 9962, operator 9963, hubble 9965), all `state=up`.

5. `platform-configs/hub/helm/kube-prometheus-stack/values-additional.yaml`
   adds `prometheus.prometheusSpec.additionalScrapeConfigs` for the two spokes:

   - job `cilium-spoke-1` → `172.19.0.3:{9962,9963,9965}`
   - job `cilium-spoke-2` → `172.19.0.4:{9962,9963,9965}`

### Refreshing spoke IPs after a rebuild

The spoke numbers are the control-plane node IPs on the `kubara-mesh` network.
After rebuilding the kind clusters:

```bash
docker inspect kubara-spoke-1-control-plane | jq '.[0].NetworkSettings.Networks.kubara_mesh.IPAddress'
docker inspect kubara-spoke-2-control-plane | jq '.[0].NetworkSettings.Networks.kubara_mesh.IPAddress'
```

Update the `additionalScrapeConfigs` targets in
`platform-configs/hub/helm/kube-prometheus-stack/values-additional.yaml`,
then let ArgoCD reconcile the hub Prometheus (or apply the values directly).

### Verifying

```bash
# hub in-cluster targets
kubectl --context kind-hub -n kube-prometheus-stack port-forward \
  pod/prometheus-kube-prometheus-stack-prometheus-0 9091:9090 &
curl -s localhost:9091/prometheus/api/v1/targets | jq -r \
  '.data.activeTargets[] | "\(.scrapePool) \(.health) \(.scrapeUrl)"'
```