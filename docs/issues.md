# Potential Issues

Analysis of the current repository state. Issues are grouped by theme and
tagged with severity. "Hardcoded IP" issues are governed by the explicit
workflow in `AGENTS.md` — several notes below are about *drift*, not the IP
policy itself.

Legend: 🔴 high — 🟠 medium — 🟡 low (severity); each entry lists
evidence (`path:line`).

---

## 1. Security

### 1.1 Commit-time default credentials in tracked config 🔴
`config.yaml:149-150` sets `adminPassword: Harbor12345`,
`databasePassword: changeit` for Harbor. Although runtime secrets come from
`.env` via `create-platform-secrets.sh`/OpenBao, the defaults are plaintext in
git history.
- Evidence: `config.yaml:147-164`; `create-platform-secrets.sh` uses
  `HARBOR_ADMIN_PASSWORD` from `.env`, but the chart values still carry the
  literal defaults.

### 1.2 Password to clipboard via login recipes 🟡
`Justfile` recipes (`login-argo-cd`, `open-argo-cd`, `open-harbor`, `open-kargo`,
`open-nexus`, `open-keycloak`, ...) pipe passwords to `pbcopy` and `echo` them to
stdout. On a shared screen this leaks credentials.
- Evidence: `Justfile:512-521`, `Justfile:629-654`.

### 1.3 Root token handling on the CLI 🟡
The OpenBao root token is parsed from a pod file and passed through shell
variables/URLs in `build-mesh.sh` and `create-platform-secrets.sh` (not
persisted, but echoed in error paths).
- Evidence: `build-mesh.sh:1085-1137`, `create-platform-secrets.sh:256-351`.

### 1.4 `.env` contains live credentials 🟠
Fine by design (git-ignored), but a breach of the host machine exposes every
platform password at once, and any script now calls out to a password-holding
env var. Consider an external secrets manager or at minimum a rotation story.
- Evidence: `.gitignore:37` ignores `.env`; `create-platform-secrets.sh:83-98`
  validates the full list of password env vars.

---

## 2. Broken / dead references

### 2.1 Missing `bin/` seed scripts 🔴
`Justfile` references `./bin/setup-go-hello.sh` (`Justfile:465-466`) and
`./bin/setup-ebank.sh` (`Justfile:488-489`), but `bin/` does not exist in this
checkout and is git-ignored (`..gitignore:75`). `just go-hello-setup` and
`just ebank-setup` fail immediately; the pipelines they seed therefore cannot
be re-established after `bring-up`.
- Evidence: `Justfile:465-471, 488-495`; directory listing of repo root.
- Also referenced in comments: `platform-configs/kubara-spoke-1/helm/kargo/values-credentials.yaml:1`.

### 2.2 Missing CoreDNS patch manifest 🔴
`just apply-coredns-patch` applies
`platform-components/coredns/coredns-configmap.yaml`, and
`refresh-coredns-hosts` writes the same path — but `platform-components/coredns/`
does not exist in the repo. Both recipes fail.
- Evidence: `Justfile:53-58, 66-109`; repo listing.

### 2.3 Missing `forgejo-build-image/` source repo 🟠
`just push-forgejo-build-image` (`Justfile:572-597`) treats
`forgejo-build-image` as a local git repo and pushes it to Forgejo; the
directory is absent from the checkout.
- Evidence: `Justfile:572-597`.

### 2.4 Traefik "inspect certificate" hardcodes a host 🟠
`Justfile:666-671` bakes `forgejo.spoke-1.kubara.test` into
`inspect-what-certificate-Traefik-is-serving`. Brittle to cluster renames but
works with the fixed host topology.

---

## 3. Config drift / single-source-of-truth problems

### 3.1 Stage labels diverge between config.yaml and the secrets scripts 🔴
`create-platform-secrets.sh` assigns labels that contradict `config.yaml`:

| Cluster | `config.yaml` stage | script label |
| --- | --- | --- |
| kubara-spoke-1 | `platform-engineering` | `dev` |
| kubara-spoke-2 | `poc` | `prod` |

- Evidence: `config.yaml:94, 260`; `create-platform-secrets.sh:32-41`.
- Consequence: OpenBao secret paths (`kv/platform/kubara-spoke-1-dev/...`) and
  the kubeconfig paths published by `build-mesh.sh`
  (`kv/hub/local/argocd/...` uses the *real* stage from
  `get_cluster_stage`) can disagree; tooling that looks up secrets by the
  "correct" stage finds nothing.

### 3.2 `dnsmasq.conf` is tracked despite being git-ignored 🟠
`dnsmasq/config/dnsmasq.conf` (git-ignored at `.gitignore:80`) carries live LB
IPs yet recent commits explicitly track it (`Stop ignoring dnsmasq...`);
`git status` shows the working copy of the file diverging from HEAD. Any PR
that commits a fresh map pollutes history with machine-specific addresses and
breaks "git is the source of truth".
- Evidence: `.gitignore:80`; commit `b99b099`; `git status`.

### 3.3 Cluster/stage knowledge is duplicated 🟠
Cluster names, contexts, stages, and hub id are re-declared in the root
`Justfile`, `build-mesh.sh`, `provision-platform.sh`,
`create-platform-secrets.sh`, `dnsmasq/Justfile`, and `config.yaml`. Adding a
cluster requires editing several files in sync; the parser in
`kind-demo-common.sh` lowers but does not remove the risk.
- Evidence: `Justfile:14-33`; `provision-platform.sh:25-36`;
  `create-platform-secrets.sh:29-41`; `dnsmasq/Justfile:117-124`.

### 3.4 `kubara generate --helm` prunes tracked charts 🟠
Kubara treats `platform-components/helm` as render output and deletes anything
it did not generate. Two charts (`template-library`, `harbor`) are rescued by
`generate-helm.sh`; `bootstrap-kubara-hub.sh` restores a fixed list of
values/redirect files. Any new hand-written chart under `platform-components/`
silently disappears on the next generate unless added to both restore lists.
- Evidence: `generate-helm.sh:13-16, 42-52`; `bootstrap-kubara-hub.sh:110-129`.

### 3.5 Spoke-2 cert-manager intentionally missing 🟡
`config.yaml` disables cert-manager on `kubara-spoke-2` (`config.yaml:272-277`)
yet **Uptime Kuma** pins `cert-manager.io/cluster-issuer:
kubara-local-ca-issuer` (`config.yaml:344-346`). Uptime Kuma's cert will not be
issued; only the hub/spoke-1 have that ClusterIssuer.
- Evidence: `config.yaml:272-277, 343-346`.

---

## 4. Robustness / operations

### 4.1 `no-resolv` + `bogus-priv` in dnsmasq 🟡
`dnsmasq.conf` sets `no-resolv`, `domain-needed`, `bogus-priv`, and
`local-ttl=0`. Correct for the scoped `/etc/resolver` zones, but if any client
forwards unrelated queries to 127.0.0.1 they all fail. Acceptable for the demo
scope; worth a comment.

### 4.2 LB IP wait windows are tight 🟠
`dnsmasq/Justfile` retries 25×4s (100s) and `bring-up` loops 120×5s (600s) for
the six traefik LBs; comments say IPs appear 30–90s after nodes start. Slow
machines / Docker cold starts can still miss the window and fail the refresh.
- Evidence: `dnsmasq/Justfile:128-139`; `Justfile:391-410`.

### 4.3 Single-node kind clusters == single points of failure 🟡
Every cluster is a single-node kind cluster; `clustermesh-apiserver` and
Postgres are single replicas. That is the correct scope for a local demo, but
it is worth recording that the demo does **not** exercise HA.

### 4.4 `resourcesPreset: nano` OOM history 🟠
Charts defaulting to `resourcesPreset: nano` (and the repo-server resource
values in `values-additional.yaml`) have caused OOM/crash loops on kind —
Postgres needed a `values-custom.yaml` fix and Argo CD repo-server needed
manual resource bumps (see git history / AGENTS.md). Any new component added
with default presets will likely repeat this.
- Evidence: `platform-configs/*/helm/postgresql/values-custom.yaml`;
  `platform-configs/hub/helm/argo-cd/values-additional.yaml:30-57`.

### 4.5 Port-forward-based testing under `just open-*` 🟡
`open-portal` uses a background `kubectl port-forward` that leaks a child
process.
- Evidence: `Justfile:505-509`.

---

## 5. Testing / observability

### 5.1 Connectivity test cleanup is manual-ish 🟠
`build-mesh.sh` scrubs `cilium-test-*` namespaces and restarts Cilium to clear
startup log noise before tests; failure modes are documented inline but there
is no automated test in CI.
- Evidence: `build-mesh.sh:1202-1236, 1238-1272`.

### 5.2 No automated end-to-end check in CI 🔴
There is no CI workflow; a long manual sequence
(`bring-up` → seeds → liquibase → pipelines) can silently rot — and has
(scripts in `bin/` missing, CoreDNS manifest missing).
- Evidence: repo has no `.github/workflows`; `renovate.json` is the only CI-ish
  file.

---

## 6. Consistency with AGENTS.md rules

### 6.1 The IP pinning rule is followed 🔴→🟢
A grep for `loadBalancerIP` finds none outside the documented exception; the
only real IPs live in `dnsmasq/config/dnsmasq.conf`. This rule is respected, so
not a bug — but it makes `dnsmasq.conf` the fragile keystone: any run of the
demo writes a new map and any stray commit of it drifts from live clusters
(see 3.2).

### 6.2 Hardcoded internal hostnames in docs only 🟡
`docs/` (this analysis) and `observability-design-options.md` are allowed to
describe the mesh conceptually but must not assert live LB IPs — kept true
throughout this documentation set.