# Networking

## Layered view

Four networking layers make the demo work:

1. **Docker bridge** — `kubara-mesh` (172.19.0.0/16). All kind nodes and the
   cloud-provider-kind load balancers hang off this one bridge. Constants live
   in the root `Justfile` and `z-demo-setup/scripts/build-mesh.sh`:
   `MESH_DOCKER_SUBNET=172.19.0.0/16`, `MESH_DOCKER_GATEWAY=172.19.0.1`,
   `MESH_DOCKER_IP_RANGE=172.19.0.10/28`. A second default `kind` network is
   kept for any unrelated local clusters (e.g. `test-cluster`) and is never
   force-detached by the demo (see `z-demo-setup/scripts/lib/kind-demo-common.sh`).
2. **Cilium ClusterMesh** — per-cluster Cilium with unique `cluster.id`
   (1..6). The hub enables ClusterMesh and `cilium clustermesh connect` links
   hub ↔ each spoke (`--allow-mismatching-ca`). This gives service identity and
   multi-cluster service connectivity between spokes.
3. **Kubernetes services** — each cluster runs its own `traefik` as a
   `LoadBalancer` service; cloud-provider-kind assigns the LB IP on the
   `kubara-mesh` bridge.
4. **Host DNS (dnsmasq)** — the only place a live IP is allowed to live:
   `dnsmasq/config/dnsmasq.conf` maps `*.kubara.test` → each cluster's traefik
   LB IP (plus `my.nexus.me` → spoke-1 Nexus and `forgejo-ssh.me` → spoke-1
   Forgejo SSH). macOS `/etc/resolver/{kubara.test,me}` send those zones to
   `127.0.0.1`.

## Why no `loadBalancerIP` pins

LoadBalancer IPs are handed out dynamically by cloud-provider-kind. Pinning
`spec.loadBalancerIP` collides with kind node IPs (nodes own `.2–.7` inside the
allocated range), and DNS must chase the real IPs anyway. Past incidents:

- Pinning an IP equal to a hub node IP left the hub traefik stuck in
  `SyncLoadBalancerFailed` or let it drift silently.
- Since DNS resolves by host, the source of truth is the *live* LB IP, not a
  committed value.

The documented workflow (see `AGENTS.md`):

1. Read the live IP:
   `kubectl ... get svc <svc> -n <ns> -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`.
2. For a new service/host, add a row in the `refresh-lb-hosts` recipe
   (`dnsmasq/Justfile`).
3. Run `just -f dnsmasq/Justfile refresh-lb-hosts` (needs sudo) to rewrite
   `dnsmasq.conf` from live IPs. The recipe refuses to write a partial/stale
   map if any required IP is missing.

## DNS resolution flow

```
<svc>.<cluster>.kubara.test
      │   macOS resolver (/etc/resolver/kubara.test)
      ▼
   127.0.0.1 dnsmasq
      │   address=/<cluster>.kubara.test/<LB-IP>
      ▼
   traefik LoadBalancer (cloud-provider-kind, on kubara-mesh)
      │
      ▼
   IngressRoute / Ingress → service → pods
```

`forgejo-ssh.me` and `my.nexus.me` are separate dnsmasq entries; they are not
placed under a `*.kubara.test` wildcard because a parent `address=` rule would
shadow them in dnsmasq's first-match order.

## CoreDNS patch

The root `Justfile` has `apply-coredns-patch` / `refresh-coredns-hosts`
recipes that inject `hosts` entries (`my.nexus.me`, `my.harbor.me`) into the
CoreDNS ConfigMap from live service ClusterIPs.

> Note: `platform-components/coredns/coredns-configmap.yaml` (referenced by
> these recipes) does not exist in the repo at the time of writing — see
> [Issues](../issues.md).

## Manual network operations

- `just start-cloud-provider-kind` / `just stop-cloud-provider-kind` — manage
  the LB controller (needs cached sudo credentials).
- `just kind-stop` / `just kind-restart` — stop/start the cluster containers +
  LBs, wait for IPs, then refresh dnsmasq.
- `just refresh-dns-lb-hosts` — rewrite the map from live IPs.
- `just start-dnsmasq` / `just stop-dnsmasq` — start/stop the host DNS.
- `z-demo-setup/scripts/setup` — idempotent DNS + LB bring-up for an
  already-built mesh.
- `just cilium-hubble-ui` — opens Hubble UI for hub + first two spokes.

## Topology recap

```
            O---------------------------- kubara-mesh 172.19.0.0/16
            |        kind clusters + cloud-provider-kind LBs
            |
   hub(id1) <-ClusterMesh-> spoke-1(id2) spoke-2(id3) dev(id4) staging(id5) prod(id6)
      │ LB IP                   │ LB IP       │ LB IP     ...
      │                         │
   dnsmasq (host) <── *.kubara.test, my.nexus.me, forgejo-ssh.me
```