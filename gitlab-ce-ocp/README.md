# GitLab CE on OpenShift (gitlab-ce-ocp)

Run **GitLab Community Edition** on a **Red Hat OpenShift (OCP)** cluster: a
production-oriented Helm chart plus the architecture, tradeoffs, and operational docs to
run it responsibly.

## What's here

```
gitlab-ce-ocp/
├── README.md                                  ← you are here
├── docs/
│   ├── architecture-review.md                 ← component model, OCP concerns, failure modes, sizing
│   ├── deployment-approaches-tradeoffs.md     ← Omnibus chart vs cloud-native chart vs Operator
│   └── installation-guide.md                  ← install, config, upgrade, backup/restore, troubleshooting
└── chart/                                      ← the Helm chart
    ├── Chart.yaml
    ├── values.yaml                            ← Phase 1: bundled, self-contained
    ├── values-production-ha.yaml              ← Phase 2: external HA datastores
    └── templates/                             ← StatefulSet, Route, dedicated SCC+RBAC, Service,
                                                  ConfigMap, Secret, backup CronJob, PDB, NetworkPolicy
```

## The one thing to understand first

"Production HA" and "bundled in-cluster datastores" are in tension, and on OpenShift the
officially *recommended* GitLab path is the **Operator** (the community cloud-native
chart doesn't deploy cleanly against OpenShift's default SCCs). This chart takes a
pragmatic, **staged** position:

1. **Phase 1 (default):** one self-contained Omnibus pod — fast, cheap, node-failure
   resilient. Great for a team/department (≤~1,000 users). Not zero-downtime HA.
2. **Phase 2 (`values-production-ha.yaml`):** keep the simple app pod, but move
   Postgres/Redis/object storage to **external HA** systems (Postgres operator, Redis
   Sentinel, ODF/S3). Removes every single point of *data* failure. **Recommended
   steady state.**
3. **Phase 3 (optional):** migrate to the **GitLab Operator** for active/active,
   zero-downtime HA — reusing the same datastores, so it's a re-point, not a rebuild.

Steps 1→2 are a values change; 2→3 reuses your data. You're not locked in by the early
decision. Full reasoning in
[`docs/deployment-approaches-tradeoffs.md`](docs/deployment-approaches-tradeoffs.md).

## Quick start

```bash
oc new-project gitlab
helm install gitlab ./chart -n gitlab \
  --set gitlab.externalUrl=https://gitlab.apps.ocp.example.com \
  --set openshift.route.host=gitlab.apps.ocp.example.com
oc rollout status statefulset/gitlab-gitlab-ce -n gitlab
```
Requires `cluster-admin` (creates a scoped SCC), Helm 3.8+, an RWO block StorageClass,
and DNS to your OCP router. First boot takes 5–15 minutes. Full steps, including the HA
path and backups, are in [`docs/installation-guide.md`](docs/installation-guide.md).

## What the chart does for OpenShift specifically

- **Dedicated SCC** (not cluster-wide `anyuid`) bound to a single ServiceAccount via a
  narrow ClusterRole/RoleBinding — the Omnibus image needs UID 0, and this grants it
  least-privilege.
- **Native Route** (edge/reencrypt/passthrough) with HTTP→HTTPS redirect; Omnibus
  configured to trust the router and not double-terminate TLS.
- **Separate SSH Service** because Git-over-SSH can't traverse the HTTP Router.
- **Three PVCs** (data/config/logs) on RWO block storage, sized independently.
- **Patient startup/readiness probes** so first-boot migrations don't trigger restart
  loops.
- **Nightly backup CronJob** that also captures `gitlab-secrets.json` (required for
  restore, and easy to forget).
- Optional **PodDisruptionBudget** and **NetworkPolicy**.

## Baseline

GitLab CE **18.8.x** (Omnibus `gitlab/gitlab-ce`), OpenShift 4.12+. Reference sizing for
≤1,000 users / 20 RPS is **8 vCPU / 16 GB** (GitLab reference architecture).

## Verification status

The chart's template control-flow and all static YAML were validated structurally. A
`helm lint`/`helm template` pass could not run in the authoring sandbox (no network to
fetch the Helm binary) — **run `helm lint ./chart` and `helm template ./chart` in your
environment before applying.** See the installation guide.

---
See [`docs/architecture-review.md`](docs/architecture-review.md) for the full
architecture review, failure-mode analysis, and security posture.
