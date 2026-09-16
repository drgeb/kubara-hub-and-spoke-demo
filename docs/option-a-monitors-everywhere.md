# Option A – ServiceMonitors everywhere (revert 3cf01ae + CRDs on spokes)

Status: Step 1 (values flips) + Step 3 (regenerate) executed 2026-09-15; Step 2 (spoke CRDs) and Step 4 (idempotent build-mesh) still pending.
Date: 2026-09-15

## Goal

Make `kubara generate --helm` / `kubara bootstrap hub --local` pass again (it currently
fails: `clusters "hub" and "kubara-spoke-1" generate conflicting content for
platform-components/helm/cert-manager/values.yaml`) while fixing the original spoke
issue at its root: spokes fail to render traefik/cert-manager/external-secrets
ServiceMonitors because `monitoring.coreos.com/v1` CRDs are missing.

## Root cause (verified)

- `serviceMonitor.enabled` for the 3 charts must be **uniform across clusters** in the
  shared `platform-components/helm/<chart>/values.yaml`. kubara's built-in monitoring
  wiring forces hub → `true` (kube-prometheus-stack enabled) regardless of catalog
  values, so a `false` base (commit `3cf01ae`) makes hub `true` vs spokes `false` →
  generation conflict. Confirmed: uniform `true` → `kubara generate --helm --dry-run`
  succeeds; uniform/inherited `false` → fails.
- Only **cert-manager, traefik, external-secrets** are enabled on both hub and >=1 spoke.
  All other charts with a `serviceMonitor` key (metrics-server, reloader, external-dns,
  oauth2-proxy, loki, velero) are hub-only or disabled → no conflict.
- Original failure driver: `monitoring.coreos.com/v1` CRDs exist only on the hub.
- The `.tplt` generator templates are left **unchanged** (they were already the
  pre-fix conditional and generation passed with `true` base).

## Step 1 – Revert the values flip (6 files, `enabled: false` → `true`)

KEEP the catalog source and the generated copy in sync (catalog is authoritative):

| File | Line | Before → After |
|---|---|---|
| `catalogs/general/platform-components/helm/cert-manager/values.yaml` | 18 | `servicemonitor.enabled: false` → `true` |
| `catalogs/general/platform-components/helm/traefik/values.yaml` | 13 | `serviceMonitor.enabled: false` → `true` |
| `catalogs/general/platform-components/helm/external-secrets/values.yaml` | 22 | `serviceMonitor.enabled: false` → `true` |
| `platform-components/helm/cert-manager/values.yaml` | 18 | `servicemonitor.enabled: false` → `true` |
| `platform-components/helm/traefik/values.yaml` | 13 | `serviceMonitor.enabled: false` → `true` |
| `platform-components/helm/external-secrets/values.yaml` | 22 | `serviceMonitor.enabled: false` → `true` |

(Equivalent to reverting the `values.yaml` hunks of commit `3cf01ae` for these 3 charts.)

## Step 2 – Install monitoring CRDs on the 5 spokes (runtime, no repo change)

`monitoring.coreos.com/v1` CRDs are missing on spoke-1, spoke-2, dev, staging, prod.

Minimal install (CRDs only, no operator/namespace): fetch prometheus-operator CRDs:

```bash
KUBE=.local/kind.kubeconfig
CRD_BASE=https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.79.2/example/prometheus-operator-crd
CRDS=(alertmanagerconfigs alertmanagers podmonitors prometheuses prometheusrules
      servicemonitors scrapeconfigs thanosrulers)
for ctx in kind-kubara-spoke-1 kind-kubara-spoke-2 kind-kubara-dev kind-kubara-staging kind-kubara-prod; do
  for crd in "${CRDS[@]}"; do
    kubectl --context "$ctx" --kubeconfig "$KUBE" apply -f \
      "${CRD_BASE}/monitoring.coreos.com_${crd}.yaml"
  done
done
```

Verify on each spoke:

```bash
kubectl --context kind-kubara-spoke-1 --kubeconfig .local/kind.kubeconfig get crd servicemonitors.monitoring.coreos.com
```

(minimum needed to unblock the 3 charts: `servicemonitors` + `prometheusrules`; the rest
are installed for completeness.)

## Step 3 – Regenerate

```bash
kubara generate --helm --dry-run   # expect: DRY-RUN successful
kubara generate --helm             # rewrites platform-components/* and platform-configs/<cluster>/*/values.generated.yaml
```

(Or skip both: `./z-demo-setup/scripts/build-mesh.sh` runs `kubara bootstrap hub --local`,
which regenerates internally.)

## Step 4 – Full idempotent re-run

```bash
./z-demo-setup/scripts/build-mesh.sh   # no --rebuild
```

Expected: cluster/helm checks, clustermesh reconnects, `kubara bootstrap hub --local`
(now green), kubeconfig publish, `provision_platform` (idempotent, already proven),
connectivity tests.

## Step 5 – Verify

```bash
# 38 apps all Synced/Healthy
kubectl --kubeconfig .local/kind.kubeconfig --context kind-hub get application -n argocd \
  -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
  | grep -v "Synced  *Healthy"

# ServiceMonitors now render on a spoke (was the original bug)
kubectl --kubeconfig .local/kind.kubeconfig --context kind-kubara-spoke-1 get servicemonitors -A | grep -E "traefik|cert-manager|external-secrets"

# DBs/roles unaffected
just verify-liquibase
```

## Impact / notes

- Hub apps are unaffected (hub already rendered ServiceMonitors fine).
- Spoke traefik/cert-manager/external-secrets apps gain ServiceMonitor/PrometheusRule
  resources; expect brief `OutOfSync → Healthy` churn during Argo sync.
- external-secrets chart already guards on CRD presence (`shouldRenderServiceMonitor`);
  cert-manager/traefik were the ones that failed — now unblocked by Step 2.
- kprom Prometheus scraping is unaffected; the hub still scrapes
  (see `observability-design-options.md`).

## Rollback

Flip the 6 `enabled: true` back to `false`, `kubara generate --helm`, re-run
`kubara bootstrap hub --local`; optionally delete the CRDs on spokes:
`kubectl delete crd servicemonitors.monitoring.coreos.com …` per spoke.