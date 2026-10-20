# GitOps & Argo CD

## Model

Argo CD deploys the **entire platform** from git `main`
(`github.com/drgeb/kubara-hub-and-spoke-demo`). Key consequences (enforced by
the repo's `AGENTS.md`):

- Local edits do **not** reach the clusters until committed, pushed, and synced.
- `selfHeal` reverts any `kubectl patch` that diverges from git.
- Fixing under-resourced components must happen in per-cluster
  `values-custom.yaml` / `values-additional.yaml`, not via live patches.

## Hub: self-managed Argo CD

- `config.yaml` marks the hub `argocd.selfManaged: enabled`; every spoke has
  `selfManaged: disabled` and `repo: {}`.
- Hub Argo CD is bootstrapped by Kubara (`z-demo-setup/scripts/bootstrap-kubara-hub.sh`
  → `kubara bootstrap hub --local`).
- Hub project `hub-local` (in
  `platform-configs/hub/helm/argo-cd/values-additional.yaml`) restricts source
  repos to the demo git repo and the external Helm repos that the stack uses.
- Ingress: `argocd.hub.kubara.test/argocd`, TLS via
  `kubara-local-ca-issuer` (cert-manager), RBAC default `role:admin`, dex
  disabled.

## How Argo CD reaches the spokes

The chain that connects hub Argo CD to the five spoken clusters:

1. `build-mesh.sh` generates a **Docker-internal** kubeconfig for each spoke
   (`kind get kubeconfig --name <svc> --internal`).
2. It **publishes each internal kubeconfig to OpenBao** at
   `kv/hub/local/argocd/<cluster>-<stage>` (see
   `z-demo-setup/scripts/lib/kind-demo-common.sh`, function
   `publish_spoke_kubeconfigs_to_openbao`).
3. Hub **External Secrets** reads those paths and materializes
   `Secrets` in the `argocd` namespace (the IngressHost address of OpenBao is
   used so the request routes to the OpenBao ingress).
4. Argo CD consumes those Secrets as cluster credentials, giving it the
   `kind-kubara-spoke-1 ... kind-kubara-prod` destinations.

Verification recipes: `just setup-openbao-secrets`, `just verify-secrets`
(secrets, ExternalSecrets status, `hub-argocd` application health).

## OpenBao as the secret backing store

- OpenBao runs on the hub in namespace `openbao`, chart `openbao/openbao`,
  bootstrapped with a local `init.json` that records the root token.
- `create-platform-secrets.sh` writes Kubernetes Secrets from `.env` values on
  every spoke **and** best-effort publishes the same values to OpenBao under
  `kv/platform/<cluster>-<stage>/...`.
- Tools here include `kv/platform/kubara-spoke-1-*/postgresql/postgresql`,
  `kargo/kargo-admin`, `forgejo/forgejo-admin`, `harbor/harbor-credentials`,
  `keycloak/keycloak-credentials`, `openproject/*`, `apicurio/apicurio-credentials`.
- External Secrets (deployed on every cluster) materialize these into
  Kubernetes Secrets so the Argo CD-managed charts never contain plaintext
  credentials.

> Stage labels used in the OpenBao path vs `config.yaml` stages can drift
> (e.g. `create-platform-secrets.sh` labels spoke-1 "dev" while `config.yaml`
> says `platform-engineering`, and spoke-2 "prod" while `config.yaml` says
> `poc`). See [Issues](../issues.md).

## bootstrap-kubara-hub.sh workaround

Kubara's `--local` bootstrap hardcodes the local DNS to
`<traefik-LB-IP>.traefik.me` (a "magic DNS"), with no flag to override it.
`z-demo-setup/scripts/bootstrap-kubara-hub.sh` runs the bootstrap then
re-pins everything back to the demo's `*.kubara.test` naming:

1. Restore the hub `dnsName` in `config.yaml`.
2. `kubara generate --helm` + restore any tracked `platform-configs` files
   containing `.traefik.me` from git.
3. Re-point the OpenBao ingress / `apiAddr` and the traefik/OpenBao value
   hostnames.
4. Verify the Argo CD ingress is `argocd.hub.kubara.test/argocd` (git-driven).

Use `just bootstrap-kubara-hub -- --skip-bootstrap` to only re-pin an existing
setup.

## Kubernetes Secret seeding

`z-demo-setup/scripts/create-platform-secrets.sh` seeds (idempotently via
`kubectl apply`):

- `postgresql/postgresql` — postgres superuser + app user passwords (on all 5
  spokes).
- spoke-1: `kargo/kargo-admin` (bcrypt hash), `forgejo/*`,
  `harbor/harbor-credentials`, `keycloak/keycloak-credentials`,
  `openproject/*`, `apicurio/apicurio-credentials`.
- `image-pull-secret` (empty registry auth) in several namespaces because
  images are public.

The secrets originate from `.env` (loaded via direnv), which is git-ignored.

## GitOps delivery pipelines

Delivery is layered on top of the same Argo CD instance managed through Kargo —
see [Delivery pipelines](./pipelines.md).

## Quick recipes

| Task | Command |
| --- | --- |
| Open Argo CD UI | `just open-argo-cd` |
| Login via CLI | `just login-argo-cd` |
| Verify spoke connections | `just verify-secrets` |
| Republish spoke kubeconfigs | `just setup-openbao-secrets` |