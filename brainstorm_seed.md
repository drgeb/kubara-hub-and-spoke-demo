# Brainstorm Seed: kubara-hub-and-spoke-demo

* **Author:** Gerald Bennett
* **Date:** 2026-11-13
* **Input for:** `/egm:egm-brainstorm`
* **Grounding:** [`repo_analysis.md`](./repo_analysis.md). Read it first. Every
  claim below points to a section there.

This file is **not** a concepts brief. It lists candidate problems found while
reading the code, so a brainstorm session can pick **one** and drill into it.
Brainstorm writes `concepts_brief.md`; do not create that file by hand.
`/egm:egm-draft` treats it as an agreed brief and skips the clarification step.

---

## How to start

Pick one concept below and run:

```text
/egm:egm-brainstorm Concept <N> from brainstorm_seed.md. Ground every claim in repo_analysis.md.
```

Brainstorm will still ask open-ended clarifying questions. The "Questions the
brainstorm must answer" list under each concept gives the session a head start
on them, not a substitute.

---

## Concept 0 (decide first): What is this lab *for*?

Every concept below depends on this answer, and the repo does not record it.

* **Observation:** The repo installs a full platform: 6 clusters, ClusterMesh,
  OpenBao, Argo CD and about 15 services. The parts that would show the
  platform working end to end, the delivery pipelines in `bin/`, are missing
  (analysis §5.4). Of 143 commits, 78 are fixes, mostly to bring-up (§5.1).
* **Tension:** If the goal is *learning how a hub-and-spoke GitOps platform
  behaves*, bring-up reliability and the delivery demo matter most. If the goal
  is *evaluating Kubara*, the repair layer (§4) is the main finding and needs to
  be written down, not hidden. If the goal is *learning Cilium ClusterMesh*, the
  platform stack is mostly noise.
* **Questions the brainstorm must answer:**
  * Who runs this, how often, and what do they need to see working at the end?
  * Which of these is a must: the six clusters, ClusterMesh, Kubara, the
    delivery pipeline?
  * What would make the lab "finished"?

---

## Concept 1: Make bring-up a reliable, observable, single-command operation

* **Problem:** A cold `just bring-up` runs 23 serial phases across six clusters
  (analysis §2). It needs two sudo prompts, one of them halfway through, and
  checks for kubara, jq and curl only when it first uses them. Its error
  messages after `$?` checks never print under `set -e` (§5.2), and it reports
  no timing. When it fails at phase 19 (OpenBao readiness), the user cannot
  tell which earlier layer is to blame: ingress, cloud-provider-kind, Argo CD
  sync, or OpenBao.
* **Possible directions (to be stress-tested, not chosen):** check every tool
  and sudo before any cluster work starts; split into resumable, named
  phases with a state marker; record per-phase durations; give each failure a
  diagnosis step; run per-cluster work in parallel where it is independent.
* **Risks to raise:** bash 3.2 limits parallel work and data structures. Making
  phases resumable adds state that can go stale. More orchestration in bash
  can add to the maintenance cost instead of reducing it.
* **Questions the brainstorm must answer:** What is an acceptable cold
  bring-up time? Is unattended operation (no sudo mid-run) a hard
  requirement? Should failures stop the run or continue with a report?

## Concept 2: Remove the Kubara repair layer

* **Problem:** `kubara bootstrap hub --local` rewrites `config.yaml`, tracked
  `platform-configs/`, and OpenBao values to traefik and `traefik.me`
  defaults. `bootstrap-kubara-hub.sh` and `generate-helm.sh` then restore
  those files from git (§4). The restore uses `git checkout --`, so **any
  uncommitted local edit to `config.yaml` or to a matching platform-configs
  file is silently lost on every bring-up.**
* **Possible directions:** run Kubara in a throwaway copy of the repo and copy
  back only the paths that are wanted; stop using `--local` and bootstrap the
  hub with plain Helm + Argo CD; contribute a DNS and ingress-class option to
  Kubara upstream; at minimum, refuse to run when those files have
  uncommitted changes.
* **Risks to raise:** dropping `--local` may lose bootstrap steps that Kubara
  does that the repo does not know about (for example, OpenBao init). An
  upstream contribution depends on maintainers the author does not control.
  A temporary-copy approach still depends on Kubara's output layout.
* **Questions the brainstorm must answer:** Is Kubara a fixed requirement of
  the lab, or one option? Which Kubara outputs does the lab actually use?

## Concept 3: One source of truth for the cluster inventory

* **Problem:** Cluster names, stages and IDs are written in seven places
  (analysis §3). Stages already disagree: `create-platform-secrets.sh` labels
  spoke-1 `dev` and spoke-2 `prod`, while `config.yaml` says
  `platform-engineering` and `poc`. As a result, OpenBao paths written by
  `build-mesh.sh` (from `config.yaml`) and by `create-platform-secrets.sh` use
  different stage segments.
* **Possible directions:** derive `kind-demo.yaml`, the Justfile contexts and
  the dnsmasq rows from `config.yaml` (it already has name, stage and
  clusterId); or have every script read one inventory through the existing
  `demo_parse_clusters` helper; add a check that fails on disagreement.
* **Risks to raise:** `config.yaml` is owned by Kubara's schema and is
  rewritten by the bootstrap (Concept 2), so building on it couples the two
  problems. Generating Justfile variables adds a build step.
* **Questions the brainstorm must answer:** Which file should own the
  inventory? Do kind-only fields (pod and service CIDRs) belong in it?

## Concept 4: Decide the role of Cilium ClusterMesh

* **Problem:** ClusterMesh takes up phases 11–14 and the optional connectivity
  test (§2), but no platform component appears to use cross-cluster services
  (§5.5). Argo CD and the metrics scraping use the shared Docker network.
* **Possible directions:** keep it and add one feature that needs it (for
  example, a global service so dev/staging/prod reach shared PostgreSQL or
  Harbor on spoke-1, or Hubble flows across clusters); or make it an opt-in
  flag and drop it from the default bring-up.
* **Risks to raise:** removing it may remove the main learning value if
  Concept 0 says the lab is about Cilium. Adding a dependency on it makes
  every service's reachability depend on mesh health.
* **Questions the brainstorm must answer:** Is ClusterMesh something to learn
  in its own right? What traffic should cross it?

## Concept 5: Restore a reproducible end-to-end delivery demo with an automated check

* **Problem:** The go-hello and ebank pipelines (Forgejo → Harbor → Kargo →
  Argo CD → dev/staging/prod) depend on git-ignored `bin/` scripts that are
  not in the repo (§5.4). Nothing automated proves the platform works after a
  bring-up (§5.5).
* **Possible directions:** move the seed scripts into `z-demo-setup/scripts/`
  under version control; define a single `just verify` that runs after
  bring-up and checks named endpoints and one pipeline promotion; add CI
  linting (shellcheck, `helm template`) where full clusters cannot run.
* **Risks to raise:** a full pipeline check needs all of spoke-1's heavy
  services, which run into the laptop memory limits (§5.5). CI cannot run six
  kind clusters on free runners.

## Concept 6: Secrets handling fit for a demo that others will copy

* **Problem:** Default passwords are committed in `config.yaml`. Routine writes
  to OpenBao use the root token read out of a pod file. OpenBao is served over
  HTTP. Recipes print passwords (§5.3).
* **Possible directions:** a scoped OpenBao policy and token for spoke
  publishing; move all defaults to `.env` + ExternalSecret; serve OpenBao over
  TLS with the existing local CA.
* **Risks to raise:** each hardening step adds bring-up phases (Concept 1) and
  can break re-runs (idempotency constraint). For a single-user local lab, the
  threat model may not justify the cost; the brainstorm should state the
  threat model before choosing.

---

## Constraints every concept must respect

Copied from `repo_analysis.md` §6. The binding text is in `AGENTS.md`.

1. No IP addresses outside the generated `dnsmasq/config/dnsmasq.conf`
   (network constants excepted).
2. bash 3.2 on macOS.
3. Explicit `--kubeconfig .local/kind.kubeconfig --context kind-<name>`.
4. The agent cannot sudo.
5. GitOps from GitHub `main`; no live `kubectl patch` fixes.
6. Bring-up and setup must stay idempotent.
7. Kubara is an external binary that this repo cannot change.

## Concepts are not independent

* Concept 0 decides which of 1–6 matter.
* Concept 3 (inventory in `config.yaml`) is blocked by Concept 2 (Kubara
  rewrites `config.yaml`).
* Concepts 5 and 6 each add phases that Concept 1 must keep reliable.
* Concept 4 changes how many phases Concept 1 has to manage.

The order with the least rework is 0 → 2 → 3 → 1, then 4, 5 and 6 as the
answer to 0 allows.
