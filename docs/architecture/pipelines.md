# Delivery Pipelines

The demo shows three example delivery paths that chain the platform tools:
source (Forgejo) → image build → registry (Harbor) → progressive delivery
(Kargo freight) → environment rollout (Argo CD into dev/staging/prod).

## go-hello

A canonical "source → artifact → environment" pipeline.

1. **Forgejo** (spoke-1) hosts the source repository and runs Actions CI.
2. **Harbor** receives built images using a robot account (secrets
   `HARBOR_USERNAME` / `HARBOR_PASSWORD` on the Forgejo repo).
3. **Kargo** watches the image as *freight* and promotes it through stages.
4. **Argo CD** syncs the application into the target cluster.

Recipes:

- `just go-hello-setup` — seed the repo/CI, Harbor robot, Argo CD + Kargo
  (`./bin/setup-go-hello.sh`).
- `just go-hello-verify` — warehouses/stages/freight/promotions + Argo app.
- `just open-go-hello` / `just go-hello-test` — `http://go-hello.dev.kubara.test/`.

> Note: `setup-go-hello.sh` lives under `bin/`, which is git-ignored and
> absent in this checkout — see [Issues](../issues.md).

## ebank

A multi-target pipeline proving the same app across environments
(dev/staging/prod), with Kargo handling promotion.

Recipes:

- `just ebank-setup` — Argo CD repo creds + AppProject/Applications
  (`./bin/setup-ebank.sh`).
- `just ebank-verify` — Kargo freight/promotions + Argo apps
  `ebank-kargo`, `ebank-dev`, `ebank-staging`, `ebank-prod`, and the
  `ebank-simple-dev` deployment.
- `just open-ebank dev|staging|prod` — `http://ebank-simple-<env>.dev.kubara.test/`.

## kargo-simple / guestbook

The stock Kargo guestbook sample promoted through `dev` and `prod` stages:

- `just open-kargo-simple dev|staging|prod` →
  `http://guestbook-simple-<env>.dev.kubara.test/`.

## Supporting recipes

- `just kargo-cli-login` — `kargo login http://kargo.spoke-1.kubara.test`
  with the admin password from `.env`.
- `just push-forgejo-build-image` /
  `just set-forgejo-harbor-secrets` — create the `forgejo-build-image` repo in
  Forgejo, push HEAD, and set the Harbor repo secrets.
- `just get-harbor-credentials` — dump the dockerconfigjson for `ebank`.

## Common pattern

```
 Forgejo (git + CI) ─► Harbor (registry) ─► Kargo (freight/promotion)
      ▲                                       │
      └──── Argo CD (git-of-gitops) ◄────────┘
                   │
            dev/staging/prod spokes
```