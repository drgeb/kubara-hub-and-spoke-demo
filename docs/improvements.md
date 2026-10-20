# Suggested Improvements

Concrete, ordered recommendations mapped to the [issues](./issues.md) they
resolve. Each is independent; the highest-value items come first.

---

## Priority 1 — restore the missing pieces

### 1.1 Rebuild the `bin/` seed scripts
Reproduce `bin/setup-go-hello.sh` and `bin/setup-ebank.sh` (or restore from
git history / contributor stash) so `just go-hello-setup` and `just ebank-setup`
work after every `bring-up`.
- Fixes: 2.1, 5.2
- Check: `bin/` exists and `just go-hello-verify` / `just ebank-verify` pass.
- Note: `bin/` is currently git-ignored (`.gitignore:75`) — consider tracking
  these scripts so they can't be lost again, or move them under
  `z-demo-setup/scripts/`.

### 1.2 Restore the CoreDNS patch manifest
Re-create `platform-components/coredns/coredns-configmap.yaml` (or delete the
two recipes if the `my.nexus.me` / `my.harbor.me` cluster-DNS aliases are no
longer wanted).
- Fixes: 2.2
- Check: `just apply-coredns-patch` no longer fails with a missing file, or the
  recipes are removed along with the `refresh-coredns-hosts` comment references.

### 1.3 Restore the `forgejo-build-image/` seed repo or document it as external
Either vendor a minimal `forgejo-build-image` repo (a Dockerfile + Forgejo
Action) or clearly document that it is created by the (missing) seed script.
- Fixes: 2.3

---

## Priority 2 — security hardening

### 2.1 Remove committed default credentials
Replace `adminPassword: Harbor12345` / `databasePassword: changeit` in
`config.yaml` with references to the ExternalSecret-backed Secret
(`harbor-credentials`) that `create-platform-secrets.sh` already seeds.
- Fixes: 1.1
- Check: `git grep -iE '12345|changeit'` returns nothing outside docs.

### 2.2 Stop echoing passwords to stdout/clipboard
Move `just open-*`/`login-*` password handling behind a thin helper that only
populates the clipboard (and prints on explicit request), or read from the
Kubernetes Secret directly instead of `.env`.
- Fixes: 1.2

### 2.3 Centralize root-token access
Wrap the OpenBao root-token read (`tr/sed` on `init.json`) in one helper in
`kind-demo-common.sh` and `unset` it in all callers (already done in the main
scripts; audit the error paths).
- Fixes: 1.3

### 2.4 Rotate base credentials now
Rotate the `.env` passwords once and re-run `provision-platform.sh`; the
scripts are idempotent, so this is a clean test of the rotation story.
Fixes 1.4 in practice; guardrails for future rotation belong in 4.2.

---

## Priority 3 — kill the drift

### 3.1 Single source for stage labels
Derive the OpenBao secret-path stage labels from `config.yaml` (reuse
`get_cluster_stage` from `build-mesh.sh` in `create-platform-secrets.sh`)
instead of the hardcoded `dev`/`prod` for spoke-1/spoke-2.
- Fixes: 3.1
- Check: OpenBao paths and `build-mesh.sh` kubeconfig paths use identical stage
  labels for every cluster.

### 3.2 Un-track `dnsmasq.conf` or generate it from one source
Pick one contract:
- (a) Keep it untracked (recommended): drop `git add` from the commit history,
  keep `.gitignore:80`, and re-run `refresh-lb-hosts` after pull/checkout; or
- (b) Track it but add a CI/`pre-commit` job that verifies it matches the live
  LBs — the current in-between state (ignored but committed) is the worst.
- Fixes: 3.2

### 3.3 Generate a cluster inventory from `config.yaml`
Let scripts read a single rendered inventory (names, contexts, stages,
cilium ids, dns names) generated from `config.yaml` + `kind-demo.yaml`, and
source it in `Justfile`, build scripts, and the dnsmasq recipe — instead of the
parallel declaration blocks.
- Fixes: 3.3

### 3.4 Guard Kubara's chart pruning
Extend `generate-helm.sh`'s `RESTORE_CHARTS` and `bootstrap-kubara-hub.sh`'s
restore list with a validation step that fails the run if any
`platform-components/helm/<svc>` directory disappears unexpectedly (compare a
manifest of expected charts vs the post-generate tree).
- Fixes: 3.4

### 3.5 Fix spoke-2 cert-manager gap
Either enable cert-manager on `kubara-spoke-2`, or drop the
`cert-manager.io/cluster-issuer` annotation from `uptime-kuma` in `config.yaml`.
- Fixes: 3.5

---

## Priority 4 — operations hardening

### 4.1 Make DNS refresh failure more visible
When `refresh-lb-hosts` aborts, print the offending host plus the last observed
IPs (already prints missing entries — good) and exit non-zero so `bring-up`
fails loudly instead of ending with a stale map.
- Fixes: 4.2
- Check: `just bring-up` on a machine with no LB IPs exits non-zero.

### 4.2 Add a credential-rotation runbook
A short `docs/operations/credential-rotation.md` describing: regenerate `.env`
values, `direnv reload`, `just create-platform-secrets`, `just provision-platform`,
restart affected deployments, re-point ExternalSecrets if keys changed.
- Fixes: 1.4, makes rotation routine.

### 4.3 Document the single-node/non-HA scope
Add a "Scope & limitations" note to the architecture docs stating that
single-replica components are intentional for the lab and not HA.
- Fixes: 4.3

---

## Priority 5 — testing & automation

### 5.1 CI smoke test (lint + dry-run)
Add a lightweight CI job:
- `helm lint` on all charts under `platform-components/helm/`,
- `bash -n` on every script in `z-demo-setup/scripts/`,
- `just generate-helm --dry-run` in a container with kubara + direnv,
- fail on any stripped `/	.cluster/` needed by a script but not present.

This alone would have caught 2.1–2.3.
- Fixes: 5.2 and hardens the repo against silent rot.

### 5.2 Convert `cilium connectivity test` into a re-runnable recipe
Wrap the multi-cluster connectivity test + namespace cleanup in a single
`just` recipe that always cleans up, so CI (or a demo day) can rerun it
without manual scrubbing.
- Fixes: 5.1

### 5.3 Add an end-to-end readiness check
Extend `test-open-apps.sh` (or `check-apps`) to assert the health of all
demo endpoints documented in the `Justfile` (`argocd`, `openbao`, `grafana`,
`forgejo`, `harbor`, `kargo`, `nexus`, `keycloak`, `uptime-kuma`, and the three
pipelines) rather than only opening them.
- Fixes: 5.2, gives `just bring-up` an exit-criterion.

---

## Quick wins

| Change | Location | Fixes |
| --- | --- | --- |
| `settings: ["gus"]` recap comment on dnsmasq scope | `dnsmasq/config/dnsmasq.conf` | 4.1 |
| Randomize `Harbor12345`/`changeit` → ExternalSecret refs | `config.yaml:149-150` | 1.1 |
| Make `inspect-what-certificate-...` take a host arg | `Justfile:666-671` | 2.4 |
| Replace `open-portal` background `port-forward` with a named foreground helper | `Justfile:505-509` | 4.5 |
| Grep CI job asserting no `loadBalancerIP` outside `dnsmasq.conf` | repo root | 6.1 |