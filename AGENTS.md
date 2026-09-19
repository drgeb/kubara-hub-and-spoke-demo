# AGENTS.md

Guidelines for coding agents working in this repository. Loaded automatically.

## IP addresses: ONE exception only

**Do not hardcode any IP address, loadBalancerIP, SSH_DOMAIN, or endpoint
address in any file — except `dnsmasq/config/dnsmasq.conf`.**

`dnsmasq/config/dnsmasq.conf` is the single generated map from the *live*
LoadBalancer IPs. It is produced by:

```
just -f dnsmasq/Justfile refresh-lb-hosts   # needs the user's sudo password
```

Why: LoadBalancer IPs are assigned dynamically by cloud-provider-kind. Pinning
`spec.loadBalancerIP` collides with kind node IPs (nodes own `.2-.7`; any pin
there gets stuck in `SyncLoadBalancerFailed` or silently drifts), and DNS must
chase the real IPs anyway. This has repeatedly broken the demo (hub traefik
died after its pin equaled the hub node IP). Do **not** re-add pins; never
encode an LB IP in chart values, ingress annotations, or scripts.

Workflow whenever a LoadBalancer IP matters:

1. Read it live: `kubectl ... get svc -n <ns> <svc> -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`.
2. If it is a new service/host, add it to the `refresh-lb-hosts` recipe rows first.
3. Regenerate the map: `just -f dnsmasq/Justfile refresh-lb-hosts` (user runs the sudo part).

### Allowed exceptions

- Network fabric constants that *define* the docker network — keep these, do
  not "make them dynamic": `MESH_DOCKER_SUBNET=172.19.0.0/16`,
  `MESH_DOCKER_GATEWAY=172.19.0.1`, `MESH_DOCKER_IP_RANGE=172.19.0.10/28`
  (in root `Justfile` and `z-demo-setup/scripts/build-mesh.sh`, passed to
  `docker network create`).
- Architecture docs (`docs/`, `observability-design-options.md`) may describe
  the subnet/CIDR conceptually, but must not assert specific live LB IPs.

## Environment

- macOS, bash 3.2.57. No `mapfile`, no associative arrays, and guard empty
  arrays under `set -u` (see the patterns in `z-demo-setup/scripts/build-mesh.sh`).
- kubectl/helm use `--kubeconfig .local/kind.kubeconfig --context kind-<name>`
  (contexts: `kind-hub`, `kind-kubara-spoke-1` ... `kind-kubara-prod`).
- The agent cannot sudo; anything needing a password (dnsmasq install/reload,
  resolver setup) is left for the user to run.

## Deploy / reconcile model

- Argo CD deploys platform components (traefik, postgres, forgejo) from git
  `main` at github.com/drgeb/kubara-hub-and-spoke-demo. Local edits do **not**
  reach clusters until pushed and synced, and a kubectl patch that diverges
  from git gets reverted by selfHeal.
- Do not fix under-resourced components with `kubectl patch`. Chart defaults
  such as `resourcesPreset: "nano"` produce OOM-killed pods; override them in
  the per-cluster `values-custom.yaml` instead (see postgres 512Mi/1Gi fix).