# buildbarn (Helm chart)

A cloud-agnostic Helm chart for [Buildbarn](https://github.com/buildbarn), a
Bazel Remote Execution API implementation. Deploys all six components as a
single release: `bb-storage`, `bb-frontend`, `bb-scheduler`, `bb-worker`,
`postgres`, and `bb-portal`.

Upstream's own [`kubernetes/`](../../kubernetes) directory ships raw
manifests + Kustomize, not a Helm chart. This chart isn't just those
manifests re-templated — it fixes real gaps along the way:

- `postgres` goes from a bare `Deployment` with **no volume at all** (data
  lost on every pod restart) to a `StatefulSet` with a real `PersistentVolumeClaim`.
- The postgres password moves out of a plaintext env var into a `Secret`.
- Every component gets resource requests/limits and readiness/liveness
  probes; none of that exists in the raw manifests.
- Most components run with a non-root `securityContext`.
- Storage class, replica/shard counts, cache sizes, and worker concurrency
  are all parameterized instead of hardcoded.
- Optional OIDC/JWT authentication (`oidc.enabled`) — off by default,
  verified to correctly reject unauthenticated requests on every
  gRPC/HTTP endpoint when turned on, and to clean up its resources when
  turned back off.

**Testing status:** everything in this chart — including OIDC on and off —
has been built and verified end-to-end against a local `kind` cluster:
real pods reaching `Running`, real Bazel builds executing remotely through
it, BES streaming to the portal UI. It has **not** been run against a
production cluster or a cloud-managed Kubernetes control plane yet.

## Prerequisites

- Kubernetes 1.24+
- Helm 3.8+
- A default `StorageClass` (or set `storageClassName` explicitly per
  component — see [Configuration](#configuration))

## Install

### From GHCR (recommended for consumers)

Published as an OCI artifact — no `helm repo add` needed:

```sh
helm install buildbarn oci://ghcr.io/suhalvemu/charts/buildbarn \
  --version 0.1.0 -n buildbarn --create-namespace
```

### From a local checkout (for development on the chart itself)

```sh
helm install buildbarn . -n buildbarn --create-namespace
```

Either way, the chart creates its own namespace by default
(`namespace.create: true`, `namespace.name: buildbarn`) — pass
`--create-namespace` above only if you also flip `namespace.create` to
`false` and want Helm managing that instead.

### Local testing on `kind`

Everything in this chart was built and verified against a local `kind`
cluster. A single-node `kind` cluster only has as many allocatable CPUs as
the host gives Docker — `worker`'s default 8 replicas alone requests 6
CPUs, more than most local setups have. For local testing:

```sh
kind create cluster --name buildbarn-dev
helm install buildbarn . --kube-context kind-buildbarn-dev --set worker.replicas=2
```

`frontend`'s and `portal-bes`'s `Service`s default to `type: LoadBalancer`,
matching upstream's manifests. On `kind` (no cloud LB controller) these
stay `<pending>` forever — that's expected, not a bug. Reach them locally
instead with:

```sh
kubectl port-forward -n buildbarn svc/portal 8081:8081
```

## Components

| Component | Workload | Notes |
|---|---|---|
| `bb-storage` | `StatefulSet` | Sharded CAS/AC/FSAC backend. Shard count == `storage.replicas`; `common.libsonnet`'s sharding config is generated to match automatically. |
| `bb-frontend` | `Deployment` | Stateless. Reuses the `bb-storage` image with a different config (`frontend.jsonnet`) — see the top-level `image` block. |
| `bb-scheduler` | `Deployment` | Owns build queueing/dispatch. Optional `Ingress` for its admin UI, off by default. |
| `bb-worker` | `Deployment` | Two containers (`worker` + `runner`) plus two init containers. Uses `emptyDir` scratch volumes by design — worker build/cache dirs are meant to be disposable. |
| `postgres` | `StatefulSet` | Backs `bb-portal`'s build-event-service database. Real `PersistentVolumeClaim` + `Secret`, unlike upstream's raw manifest. |
| `bb-portal` | `Deployment` | Web UI + build-event-service gRPC endpoint. Two `Service`s (`portal` for HTTP, `portal-bes` for gRPC) + optional `Ingress`. |

## Configuration

Full defaults are in [`values.yaml`](values.yaml). Highlights:

| Key | Default | Description |
|---|---|---|
| `namespace.create` | `true` | Set `false` to install into a namespace you manage elsewhere |
| `global.maximumMessageSizeBytes` | `16777216` | Largest single gRPC message any component accepts |
| `storage.replicas` | `2` | Also controls shard count in `common.libsonnet` |
| `storage.storageClassName` | `""` (cluster default) | Set explicitly for cloud, e.g. `gp3` (EKS), `premium-rwo` (GKE) |
| `storage.cas/ac/fsac.pvcSizeGi` | `33` / `1` / `1` | PVC sizes per backend |
| `frontend.replicas` | `3` | |
| `frontend.service.type` | `LoadBalancer` | |
| `scheduler.ingress.enabled` | `false` | Upstream hardcodes `bb-scheduler.example.com`; not portable, so off by default |
| `worker.replicas` | `8` | Sized for a real cluster — see [Local testing](#local-testing-on-kind) for local overrides |
| `worker.concurrency` | `8` | Concurrent build actions per worker pod |
| `worker.cache.maximumSizeBytes` | `1073741824` (1 GiB) | Per-worker local build cache |
| `postgres.password` | `"password"` | **Local-testing default only.** Override via `--set postgres.password=...` or a values file for anything real |
| `postgres.existingSecret` | `""` | Point at a pre-created `Secret` (key `password`) instead of letting the chart manage one |
| `postgres.pvcSizeGi` | `5` | |
| `portal.companyName` | `"Example Co"` | Displayed in the web UI |
| `portal.ingress.enabled` | `false` | Same reasoning as `scheduler.ingress` — `bb-portal.example.com` isn't portable |
| `oidc.enabled` | `false` | Switches every component's `authenticationPolicy` from `allow: {}` to JWT validation. `bb-worker`'s internal registration traffic stays unauthenticated regardless — it has no OIDC identity to present |
| `oidc.jwksUrl` | Google's JWKS endpoint | Your OIDC provider's JWKS URL (not the discovery URL) |
| `oidc.audience` | `"buildbarn-cluster"` | Required `aud` claim value; tokens without a match are rejected |
| `oidc.syncJob.schedule` | `"*/15 * * * *"` | How often the JWKS ConfigMap refreshes |

## What's not here yet

- Not yet opened as a PR to `buildbarn/bb-deployments` upstream.
- `bb-worker`'s `securityContext` intentionally matches upstream (worker
  container: none; runner sidecar: `runAsUser: 65534`) rather than forcing
  non-root on `worker` — it wasn't verified whether the worker binary needs
  elevated permissions, so this wasn't changed without confirming that first.
- No ArgoCD `Application` wrapper or Terraform module for the underlying
  cluster (both planned as follow-on layers, not started).
