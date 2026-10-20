# Platform Services

Platform engineering tools and backing services, grouped by cluster. Desired
state is declared per service in `config.yaml`; rendered Helm values live under
`platform-configs/<cluster>/helm/<service>/`; charts under
`platform-components/helm/<service>/`.

## hub — control plane & observability

| Service | Namespace | Role |
| --- | --- | --- |
| Argo CD | `argocd` | GitOps controller (self-managed) |
| OpenBao | `openbao` | Secrets engine: spoke kubeconfigs + platform credentials |
| kube-prometheus-stack | `monitoring` | Prometheus, Grafana, Alertmanager, ServiceMonitors |
| metrics-server | `kube-system` | Horizontal metrics (HPA) |
| cert-manager | `cert-manager` | TLS certs; `kubara-local-ca-issuer` + `letsencrypt-staging` |
| External Secrets | `external-secrets` | Materializes secrets from OpenBao |
| Homer dashboard | `homer-dashboard` | Service dashboard |
| Traefik | `traefik` | Entrypoint + ingress controller |

## kubara-spoke-1 — platform engineering

This spoke hosts the "platform" the dev/staging/prod spokes consume.

| Service | Namespace | Role |
| --- | --- | --- |
| Forgejo | `forgejo` | Git hosting + Actions CI |
| Harbor | `harbor` | Container registry (hostname `harbor.spoke-1.kubara.test` + `my.harbor.me`) |
| Kargo | `kargo` | Progressive delivery / freight promotion (Argo CD + Rollouts integrations) |
| Nexus | `nexus` | Repository manager (Maven proxy; `my.nexus.me`) |
| Keycloak | `keycloak` | IAM / SSO (realm, clients for the platform tools) |
| OpenProject | `openproject` | Project management |
| Apicurio | `apicurio` | API design / registry (Liquibase-managed DB) |
| OPA | `opa` | Policy engine (admission webhook) |
| PostgreSQL (bitnami) | `postgresql` | Shared backing DB (dbs: forgejo, keycloak, openproject, apicurio) |
| cert-manager / External Secrets / Homer / Traefik | | shared platform plumbing |

DB schemas/roles are provisioned by Liquibase (`z-demo-setup/liquibase/`),
bootstrapped via `provision-platform.sh`.

## kubara-spoke-2 — POC / evaluation

| Service | Namespace | Role |
| --- | --- | --- |
| Kafka | `kafka` | Message bus (Strimzi-style operator, `my-kafka`) |
| Ollama | `ollama` | Local LLM inference (llama3.2, 30Gi storage) |
| Uptime Kuma | `uptime-kuma` | Uptime monitoring dashboard |
| PostgreSQL (bitnami) | `postgresql` | `app` database (8Gi) |
| PostgreSQL 19 (CloudNativePG) | `postgresql19` | Operator-managed cluster (`postgresql19-1`, `app` db, 8Gi) |
| External Secrets / Homer / Traefik | | plumbing |

## kubara-dev / kubara-staging / kubara-prod — workload targets

Each runs a minimal platform base:

- Traefik (ingress) + cert-manager (`letsencrypt-staging`) + External Secrets +
  Homer dashboard
- PostgreSQL (bitnami) with an `app` database/user

These are the environments that Kargo promotes workloads into.

## Notable configuration facts

- **Harbor** (`config.yaml`): `adminPassword: Harbor12345`,
  `databasePassword: changeit`, hostname `harbor.spoke-1.kubara.test` with
  additional host `my.harbor.me`, storage 10Gi+1Gi+1Gi, TLS via local CA.
  See [Issues](../issues.md) about committed defaults.
- **Forgejo**: admin `gitea_admin`, DB `forgejo` on the shared postgres with
  user `app`; TLS via `kubara-local-ca-issuer`.
- **Nexus**: TLS via local CA; maven alias `my.nexus.me`; Forgejo SSH LB uses a
  separate host `forgejo-ssh.me`.
- **Kargo**: Argo CD + Rollouts integrations enabled, TLS via local CA, admin
  credentials from `kargo-admin` Secret (bcrypt hash).
- **PostgreSQL sizing fix**: chart defaults (e.g. `resourcesPreset: nano`)
  OOM-kill pods; each cluster carries an override in
  `platform-configs/<cluster>/helm/postgresql/values-custom.yaml`
  (e.g. 512Mi request / 1Gi limit).

## Access endpoints (`.env` credentials)

| Tool | URL |
| --- | --- |
| Argo CD | `https://argocd.hub.kubara.test/argocd` |
| Grafana / Prometheus / Alertmanager | `https://*.hub.kubara.test` |
| OpenBao | `https://openbao.hub.kubara.test` |
| Forgejo / Harbor / Kargo / Nexus / Keycloak | `https://*.spoke-1.kubara.test` |
| Uptime Kuma | `https://uptime-kuma.spoke-2.kubara.test` |

The `open-*` recipes in the `Justfile` open each UI and copy the password to
the clipboard.