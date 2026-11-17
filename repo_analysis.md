# Repository Analysis: kubara-hub-and-spoke-demo

* **Author:** Gerald Bennett
* **Date:** 2026-11-13
* **Commit analyzed:** `89037c0` (main, clean tree)
* **Purpose of this file:** Grounded "as-is" description of the repository, for
  `/egm:egm-brainstorm` and its Goldfish reviewers. It states what the code does
  today and where it is fragile. It does not propose a design. Candidate
  problems to brainstorm are in [`brainstorm_seed.md`](./brainstorm_seed.md).

---

## 1. What the repository is trying to do

On one macOS laptop, the repo builds a working copy of a multi-cluster internal
developer platform:

* **Six kind clusters** (Kubernetes in Docker), all attached to one Docker bridge
  network named `kubara-mesh`.
* **Cilium** is the network plugin (CNI) and the Ingress controller in every
  cluster. **Cilium ClusterMesh** links the hub to each spoke.
* **Kubara**, an external CLI, bootstraps the hub. It also turns `config.yaml`
  into per-cluster Helm values under `platform-configs/`.
* **Argo CD**, which runs on the hub and manages itself, deploys every platform
  component to every cluster from git `main` on GitHub.
* **OpenBao** (a fork of Vault) on the hub stores the spoke credentials. External
  Secrets turns those entries into Kubernetes Secrets: Argo CD cluster secrets
  and application passwords.
* A set of **platform-engineering tools** runs on `kubara-platform-engineering`: Forgejo,
  Harbor, Kargo, Nexus, Keycloak, OpenProject, Apicurio and OPA. They feed a
  delivery pipeline into the `dev`, `staging` and `prod` spokes.
* **dnsmasq** on the host resolves `*.<cluster>.kubara.test` to each cluster's
  ingress LoadBalancer IP, so a browser on the Mac can reach every service by
  name.

In short, it is a learning and demonstration lab. It shows how a GitOps-managed
hub-and-spoke platform behaves end to end, from cluster creation to a running
delivery pipeline, without any cloud account.

### Cluster inventory (`z-demo-setup/config/kind-demo.yaml` + `config.yaml`)

| Cluster | Stage | Cilium ID | Pod / Service CIDR | Role |
| --- | --- | --- | --- | --- |
| `hub` | `local` | 1 | 10.10/16, 10.96/16 | Argo CD (self-managed), OpenBao, kube-prometheus-stack, metrics-server, cert-manager, homer |
| `kubara-platform-engineering` | `platform-engineering` | 2 | 10.20/16, 10.97/16 | Forgejo, Harbor, Kargo, Nexus, Keycloak, OpenProject, Apicurio, OPA, PostgreSQL |
| `kubara-poc` | `poc` | 3 | (overlay) | Kafka, Ollama, Uptime Kuma, PostgreSQL, PostgreSQL 19 (CNPG) |
| `kubara-dev` | `dev` | 4 | (overlay) | Workload target + PostgreSQL |
| `kubara-staging` | `staging` | 5 | (overlay) | Workload target + PostgreSQL |
| `kubara-prod` | `prod` | 6 | (overlay) | Workload target + PostgreSQL |

Every cluster is a single node. Nothing is highly available.

---

## 2. The bring-up path, step by step

Entry point: `just bring-up [-- --rebuild] [-- -t]` (`Justfile:385`). It runs
`z-demo-setup/scripts/build-mesh.sh`, waits for six `cilium-ingress`
LoadBalancer IPs, and then runs `just refresh-lb-hosts`.

`build-mesh.sh` `main()` (`build-mesh.sh:1396`) runs these phases in order.
Every phase runs **serially across all six clusters**.

| # | Phase | Function (line) | What it does | External dependency |
| --- | --- | --- | --- | --- |
| 1 | Load inventory | `demo_load_config` / `demo_parse_clusters` (101–141) | Reads `kind-demo.yaml` into parallel bash arrays. Checks that the hub is first with ID 1 and that IDs are unique. | awk parser in `lib/kind-demo-common.sh` |
| 2 | Prerequisites | `check_prerequisites` (158) | Checks that kind, kubectl, cilium and docker exist and Docker is running. Does **not** check helm, jq, curl, kubara or just until later. | — |
| 3 | Helm repos | `ensure_cilium_helm_repo`, `ensure_prometheus_helm_repo` (218, 237) | Adds and updates the repos on every run. | Internet |
| 4 | Docker networks | `check_kind_network`, `ensure_mesh_docker_network` (273, 256) | Creates `kind` and `kubara-mesh` (172.19.0.0/16, IP range .10/28). | Docker |
| 5 | Clusters | `create_clusters` (341) | `KIND_EXPERIMENTAL_DOCKER_NETWORK=kubara-mesh kind create cluster`. Skips clusters that exist. `--rebuild` deletes them first. | kind |
| 6 | Kubeconfigs | `generate_kubeconfigs` (349) | A merged temporary kubeconfig for the script, plus a persistent `.local/kind.kubeconfig`. | — |
| 7 | API ready | `wait_for_api` (420) | Polls `/readyz` for up to 300 s per cluster. | — |
| 8 | Prometheus CRDs on hub | `ensure_hub_prometheus_crds` (447) | `helm show crds kube-prometheus-stack 88.6.3 \| kubectl apply --server-side`, so the Cilium ServiceMonitors can be created on the hub before Argo CD exists. | Internet |
| 9 | Cilium | `install_all_cilium` → `install_cilium` (469) | `cilium install` with kube-proxy replacement, a shared-mode Ingress controller and Hubble metrics. ServiceMonitors only on the hub. Then **always** restarts the operator and agent, and waits for the `cilium-ingress` LB IP. | cilium CLI, cloud-provider-kind (for the LB IP) |
| 10 | Cilium ready | `wait_for_cilium`, `wait_for_nodes` (670, 428) | `cilium status` and node Ready. | — |
| 11 | ClusterMesh enable | `enable_all_clustermesh` (959) | `cilium clustermesh enable --service-type NodePort`, then `helm upgrade --reuse-values` to force one API-server replica. | — |
| 12 | ClusterMesh connect | `connect_clusters` (1026) | Connects the hub to each spoke (a star; spokes are not connected to each other). `--allow-mismatching-ca`. | — |
| 13 | Replicas again | `enforce_clustermesh_replicas` (965) | Repeats the replica=1 upgrade on every cluster. | — |
| 14 | Mesh connected | `wait_for_mesh_connections` (833) | Parses the text output of `cilium clustermesh status` with regexes. | cilium CLI output format |
| 15 | cloud-provider-kind | `check_cloud_provider_kind` (1042) | If cloud-provider-kind is not running, calls **`sudo -v`** and `just start-cloud-provider-kind`. | sudo, just |
| 16 | Hub bootstrap | `bootstrap_kubara_hub` → `bootstrap-kubara-hub.sh` | `kubara bootstrap hub --local`, followed by six repair steps (see §4). | kubara binary, git |
| 17 | Spoke kubeconfigs | `generate_internal_kubeconfigs` (1071) | `kind get kubeconfig --internal` per spoke (API address on the Docker network). | — |
| 18 | Stages | `set_values_to_publish_spoke_kubeconfigs_to_openbao` (1123) | Reads each cluster's `stage` out of `config.yaml` with awk. | — |
| 19 | OpenBao ready | `wait_for_openbao` (1165) | Curls `/v1/sys/health` through the hub `cilium-ingress` LB IP with a `Host:` header, for up to 300 s. | Argo CD + OpenBao + cilium ingress all healthy |
| 20 | Publish kubeconfigs | `publish_spoke_kubeconfigs_to_openbao` (1193) | Reads the OpenBao **root token** with `kubectl exec ... init.json`, then POSTs each kubeconfig to `kv/hub/local/argocd/<cluster>-<stage>`. | curl, jq |
| 21 | Platform provisioning | `provision_platform` → `provision-platform.sh` | Creates secrets from `.env` on every spoke, waits for PostgreSQL, then runs Liquibase helm jobs that create roles and databases. | `.env`, Argo CD having deployed PostgreSQL |
| 22 | Report | `verify_cluster_config` … `show_clustermesh_services` | Prints status. | — |
| 23 | Optional test | `test_connectivity` (1382) | With `-t`: cleans up old `cilium-test-*` namespaces, restarts Cilium everywhere, runs `cilium connectivity test --multi-cluster` from the hub to each spoke. | — |

After `build-mesh.sh`, the `bring-up` recipe waits up to 600 s for all six
`cilium-ingress` IPs. It then calls `dnsmasq/Justfile refresh-lb-hosts`, which
rewrites `dnsmasq/config/dnsmasq.conf` and needs **a second sudo prompt**.

### How the hub reaches the spokes (secret flow)

```text
kind get kubeconfig --internal (spoke)        build-mesh.sh step 17
        │
        ▼  curl POST with the root token
OpenBao kv/hub/local/argocd/<cluster>-<stage> (hub)
        │
        ▼  ExternalSecret "<cluster>-es" (argo-cd chart, templates/cluster.yaml)
Secret <cluster>-cluster-secret, label argocd.argoproj.io/secret-type=cluster
        │
        ▼  ApplicationSet cluster generator, matchLabels {<app>: enabled}
Argo CD Applications per (cluster × enabled service)
        │
        ▼  sources: platform-components/helm/<app> + platform-configs/<cluster>/helm/<app>/values*.yaml
Workloads on each spoke
```

### How a browser reaches a service (DNS flow)

```text
browser → macOS /etc/resolver/kubara.test → dnsmasq (host)
        → address=/<cluster>.kubara.test/<live cilium-ingress LB IP>
        → cloud-provider-kind LB container on kubara-mesh
        → cilium-ingress (shared mode, kube-system) → Ingress → Service
```

---

## 3. Where each fact is defined (sources of truth)

| Fact | Defined in | Also hardcoded in |
| --- | --- | --- |
| Cluster names | `z-demo-setup/config/kind-demo.yaml` | `config.yaml`; `provision-platform.sh:25-37`; `create-platform-secrets.sh:15-41`; root `Justfile` (contexts and DNS names, ~line 45); `dnsmasq/Justfile` `ROWS`; `build-mesh.sh` closing banner (1464) |
| Cluster stage | `kind-demo.yaml` **and** `config.yaml` (two copies) | `create-platform-secrets.sh` uses **different** values: platform-engineering=`dev`, poc=`prod` (`config.yaml` says `platform-engineering`, `poc`) |
| Cilium cluster ID | `kind-demo.yaml` **and** `config.yaml` `services.cilium.config.clusterId` | — |
| Cilium Helm settings | `build-mesh.sh:495-542` (`--set` flags) | chart `platform-components/helm/cilium/values.yaml` and its catalog copy (the comment says these "must match") |
| Enabled services per cluster | `config.yaml` | rendered into `platform-configs/<cluster>/helm/*/values.generated.yaml` by Kubara |
| Durable value overrides | `platform-configs/<cluster>/helm/<app>/values-additional.yaml` / `values-custom.yaml` | Kubara's bootstrap rewrites some of these files, and `bootstrap-kubara-hub.sh` puts them back from git |
| Live LB IPs | `dnsmasq/config/dnsmasq.conf` (generated, the one allowed IP file per `AGENTS.md`) | `observability-design-options.md` (node IPs in prose, which AGENTS.md allows for architecture docs) |
| Desired cluster state | git `main` on GitHub | Local edits do nothing until pushed, and Argo CD `selfHeal` reverts live patches |

---

## 4. The "repair layer": code that undoes other tools

A large share of the orchestration exists to reverse what a tool just did.
These are the clearest signs of the repository's structural problems.

| Tool behaviour | Repair code | Side effect of the repair |
| --- | --- | --- |
| `kubara bootstrap hub --local` rewrites `config.yaml`: the hub `dnsName` becomes `<LB-IP>.traefik.me`, `ingressClassName` becomes `traefik`, and cilium is disabled | `restore_config_yaml`: `git checkout -- config.yaml` | **Silently discards any uncommitted local edit to `config.yaml`** on every bring-up |
| Kubara rewrites tracked `platform-configs/**` values with traefik defaults | `restore_tracked_platform_configs`: `git checkout` on every tracked file that mentions traefik | Same risk: uncommitted edits in those files are lost |
| Kubara renders a `platform-configs/*/helm/traefik/` directory that is no longer in the catalog | `remove_generated_traefik_configs`: `rm -rf` | — |
| Kubara writes `.local/openbao/values.yaml` with `ingressClassName: traefik` | `repoint_openbao`: `helm upgrade --reuse-values --set ...cilium` plus a `sed` on the values file | The OpenBao release now differs from the file Kubara owns |
| `kubara generate --helm` prunes `platform-components/helm/template-library` and `harbor` | `generate-helm.sh`: `rm -rf` and `cp -R` from `catalogs/` | Charts are copied, not referenced, so a fix made in one copy does not reach the other |
| `kubara generate --helm` drops the durable overrides (argo-cd root values, cert-manager local CA, homer, kube-prometheus-stack) | `restore_demo_overrides`: `git checkout` on four named files | — |
| The Cilium operator reads `ingress-hostnetwork-enabled` only once, at startup, and the agent ignores `kubeProxyReplacement` changes until restarted | `restart_cilium_components`, run after **every** install and re-run | Adds a rollout restart for every cluster on every run |
| `cilium clustermesh enable` ignores the replica setting | Two separate `helm upgrade --reuse-values` passes (steps 11 and 13) | — |

The root cause: **Kubara's `--local` mode is designed for a single
traefik-fronted cluster with `traefik.me` magic DNS.** This repo uses Cilium
ingress, a custom DNS zone and six clusters, so every bootstrap is followed by
reverting Kubara's output from git.

---

## 5. Observed weaknesses (evidence-backed)

### 5.1 Change churn
* 143 commits between 2026-09-02 and 2026-10-21. **78 subjects start with
  `fix`**, and 39 mention traefik, DNS, LB or cloud-provider-kind. Most of the
  effort goes into keeping bring-up working, not into adding platform features.
* The traefik → Cilium ingress migration took two commits (`9622148`,
  `89037c0`). Docs still describe Traefik: `docs/architecture/overview.md`
  (component table "Traefik ingress ✔" on all clusters), `networking.md`,
  `gitops-and-argocd.md`. `AGENTS.md` still says bring-up waits for "the six
  traefik LB IPs".

### 5.2 Correctness and robustness in `build-mesh.sh`
* `if [ $? -ne 0 ]` checks after commands under `set -Eeuo pipefail` (lines
  336, 547, 925, 945, 954) never run. The script has already exited on the
  failure, so the custom `die` messages are never printed.
* The closing banner (1473–1480) tells the user to run
  `bootstrap-kubara-hub.sh` again, but step 16 already ran it. The banner also
  hardcodes the 6-cluster topology and the name `test-cluster`.
* `wait_for_mesh_connections` depends on the exact text output of `cilium
  clustermesh status` (regex at 864). A Cilium CLI upgrade can break it
  without warning.
* `check_cloud_provider_kind` runs `sudo -v` in the middle of the script. An
  unattended or agent-run bring-up stops there, and `AGENTS.md` says the agent
  cannot sudo.
* Tools are checked only when first needed: helm (step 3), jq and curl
  (step 20), kubara (step 16). A missing `kubara` fails about 10 minutes in,
  after the clusters and Cilium are already up.
* Everything runs serially across six clusters. There are no timings or
  per-phase durations, so nobody knows how long a cold bring-up takes or which
  phase is slow.

### 5.3 Security
* Default credentials committed in `config.yaml` (`adminPassword:
  Harbor12345`, `databasePassword: changeit`).
* The OpenBao **root token** is read with `kubectl exec` from a file on the pod
  (`init.json`) and used for routine writes. There is no scoped policy or token.
* OpenBao is reached over plain HTTP through the ingress.
* `.env` holds the base passwords. Several `just open-*` / `login-*` recipes
  print or copy passwords.

### 5.4 Missing or dead pieces (`docs/issues.md` §2)
* `bin/setup-go-hello.sh`, `bin/setup-ebank.sh` (git-ignored, absent): the
  `just go-hello-*` / `ebank-*` delivery-pipeline demos cannot run from a
  fresh clone, so **the delivery pipeline is not reproducible.**
* `platform-components/coredns/coredns-configmap.yaml` is missing (used by
  `just apply-coredns-patch`).
* The `forgejo-build-image/` seed repo is missing.
* `lib/kind-demo-common.sh` still contains about 280 lines of Sveltos parsing
  (`demo_parse_sveltos_bootstrap`, `demo_parse_cluster_registration`) that
  nothing in the bring-up path calls.

### 5.5 Architecture questions the code does not answer
* **What is ClusterMesh used for?** No tracked manifest outside `catalogs/`
  uses a Cilium global-service annotation. Argo CD reaches the spokes through
  their Docker-internal API addresses, not through the mesh. Cross-cluster
  metrics scraping, as described in `observability-design-options.md`, used
  node IPs on the Docker network. ClusterMesh may be installed, waited on and
  tested without carrying any platform traffic.
* **Why six clusters?** `dev`, `staging` and `prod` run the same small set
  (PostgreSQL, cert-manager, external-secrets, homer) and no workloads until
  the missing `bin/` scripts run. Each cluster adds a serial pass through
  every phase in §2 (time not measured) and memory pressure on the laptop. Past OOM problems are recorded in
  `AGENTS.md` and `docs/issues.md` §4.4.
* **What is "done"?** There is no automated end-to-end check (`docs/issues.md`
  §5.2). Success today is that `build-mesh.sh` exits 0 and a human opens the
  URLs. `test-open-apps.sh` exists as a post-step but is not part of
  `bring-up`.

---

## 6. Hard constraints (from `AGENTS.md` and the environment)

1. No IP addresses, `loadBalancerIP` pins or endpoint addresses in any file
   except the generated `dnsmasq/config/dnsmasq.conf`. The Docker network
   constants (`172.19.0.0/16`, `.1`, `.10/28`) are the only allowed
   exception.
2. macOS bash 3.2: no `mapfile`, no associative arrays, and guard empty arrays
   under `set -u`.
3. kubectl and helm always use `--kubeconfig .local/kind.kubeconfig --context
   kind-<name>`.
4. The agent cannot sudo. dnsmasq, the resolver and cloud-provider-kind
   start-up are left to the user.
5. Argo CD deploys from GitHub `main`. Fixes must be committed and pushed, not
   applied with `kubectl patch`. Resource fixes go in per-cluster
   `values-custom.yaml`.
6. Repeated runs of `bring-up` / `setup` must be safe (idempotent).
7. Kubara is an external binary. The repo cannot change its `--local`
   behaviour; it can only wrap it or replace it.

---

## 7. Key files for reviewers

| Path | Why it matters |
| --- | --- |
| `z-demo-setup/scripts/build-mesh.sh` | The orchestrator analyzed above (1,485 lines) |
| `z-demo-setup/scripts/bootstrap-kubara-hub.sh` | Kubara wrapper and repair layer |
| `z-demo-setup/scripts/generate-helm.sh` | `kubara generate` wrapper and chart restore |
| `z-demo-setup/scripts/provision-platform.sh` | Secrets, PostgreSQL wait, Liquibase |
| `z-demo-setup/scripts/create-platform-secrets.sh` | `.env` → Secrets + OpenBao (divergent stage labels) |
| `z-demo-setup/scripts/lib/kind-demo-common.sh` | Shared helpers and the inventory parser |
| `z-demo-setup/scripts/sync-lb-dns.sh` | Idempotent DNS + LB layer for an already built mesh |
| `z-demo-setup/config/kind-demo.yaml` | Cluster inventory |
| `config.yaml` | Kubara desired state |
| `Justfile` (`bring-up`, line 385) | Top-level entry point |
| `dnsmasq/Justfile` (`refresh-lb-hosts`, line 105) | DNS map generator |
| `platform-components/helm/argo-cd/templates/{cluster,appsets}.yaml` | How OpenBao entries become Argo CD clusters and Applications |
| `docs/issues.md`, `docs/improvements.md` | Existing issue list (partly outdated: it still mentions traefik) |
| `AGENTS.md` | Binding rules for agents |
