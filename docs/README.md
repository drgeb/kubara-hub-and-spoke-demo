# Kubara Hub-and-Spoke Demo — Documentation

Analysis and documentation of the codebase in this repository: a local
multi-cluster Kubernetes lab built with **kind**, Cilium ClusterMesh, and
**Kubara**, where **Argo CD** manages the whole platform from git and a set of
platform-engineering tools (Forgejo, Harbor, Kargo, Nexus, Keycloak, ...) run
"as a platform" in front of dev/staging/prod spokes.

## Contents

| Section | What it covers |
| --- | --- |
| [Architecture](./architecture/overview.md) | High-level topology, components, roles of each cluster |
| [Networking](./architecture/networking.md) | Docker mesh, Cilium ClusterMesh, Traefik LBs, dnsmasq DNS |
| [GitOps & Argo CD](./architecture/gitops-and-argocd.md) | How Argo CD manages infra + spokes; OpenBao secret flow |
| [Platform services](./architecture/platform-services.md) | Per-cluster service inventory (Nexus, Harbor, Forgejo, Kargo, ...) |
| [Delivery pipelines](./architecture/pipelines.md) | go-hello, ebank, kargo-simple example pipelines |
| [Issues](./issues.md) | Potential problems found in the current state |
| [Improvements](./improvements.md) | Concrete suggested improvements |
| [Diagrams](./diagrams/) | Standalone rendered diagrams (archify HTML) |

## Orientation

- Orchestration: root `Justfile` recipes + `z-demo-setup/scripts/*`.
- Desired state: `config.yaml` (per-cluster stage + services), rendered to
  `platform-configs/<cluster>/helm/*`.
- Helm charts live in `platform-components/helm/`, restored / pruned by
  `kubara generate --helm` (see `z-demo-setup/scripts/generate-helm.sh`).
- The "allowed" source of truth for live LoadBalancer IPs is
  `dnsmasq/config/dnsmasq.conf`; nothing else should hardcode IPs.

## Reading order for newcomers

1. `docs/architecture/overview.md` — the big picture.
2. `docs/architecture/gitops-and-argocd.md` — the control plane.
3. `docs/architecture/networking.md` — the fabric the demo lives on.
4. `docs/issues.md` then `docs/improvements.md`.

## Generated tooling

- Diagrams in `docs/diagrams/` are produced with the `archify` skill from the
  JSON specs next to each HTML file.
  - `high-level-architecture.html` — host tooling, kubara config, git, and the
    hub core (traefik/OpenBao/Argo CD) managing dev/staging/prod spokes.
  - `gitops-and-secrets-flow.html` — the Git→OpenBao→ExternalSecrets→Argo CD
    secret and configuration flow plus kubara provisioning.
  - `delivery-pipeline-flow.html` — the Forgejo→Harbor→Kargo→Argo CD delivery
    pipeline with approval gate and rollback.
  - Regenerate with e.g. `node /Users/drgeb/.agents/skills/archify/bin/archify.mjs render architecture docs/diagrams/high-level-architecture.json ... --repo-root .`.
- Files under `docs/archify/` are an earlier alternative diagram exploration;
  the current diagrams are under `docs/diagrams/`.