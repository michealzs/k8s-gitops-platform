# Architecture

This repository is the single source of truth for two Kubernetes clusters, `dev-eks` and `prod-eks`. Each cluster runs its own Argo CD, and each Argo CD watches the `main` branch of this repository. Nothing is applied to a cluster by hand after bootstrap.

## Sync flow

```mermaid
flowchart LR
    eng["Engineer"] -->|"pull request, CI, review, merge"| repo[("GitHub main branch")]

    subgraph devc["dev-eks"]
        argo_dev["Argo CD"] --> root_dev["root-dev Application"]
        root_dev --> plat_dev["platform Applications"]
        root_dev --> as_dev["apps ApplicationSet"]
        plat_dev -->|"helm charts + values-dev.yaml"| dev_ns["ingress-nginx, cert-manager, monitoring, ..."]
        as_dev -->|"apps/*/overlays/dev"| dev_apps["podinfo Deployment"]
    end

    subgraph prodc["prod-eks"]
        argo_prod["Argo CD"] --> root_prod["root-prod Application"]
        root_prod --> plat_prod["platform Applications"]
        root_prod --> as_prod["apps ApplicationSet"]
        plat_prod -->|"helm charts + values-prod.yaml"| prod_ns["ingress-nginx, cert-manager, monitoring, ..."]
        as_prod -->|"apps/*/overlays/prod, manual sync"| prod_apps["podinfo Rollout (canary)"]
    end

    repo -->|"poll every 3m or webhook"| argo_dev
    repo -->|"poll every 3m or webhook"| argo_prod
```

## Layers

**Bootstrap.** `bootstrap/argocd` holds the Argo CD Application that points at the upstream `argo-cd` chart and at `bootstrap/argocd/values.yaml` in this repository. The first install is a plain `helm install`; once Argo CD is up, applying that Application makes Argo CD manage its own release. `bootstrap/<cluster>/root-app.yaml` is the root of the app-of-apps: one Application whose source is `clusters/<cluster>`.

**Clusters.** `clusters/<cluster>` is a kustomization that renders every Argo CD resource for that cluster: two AppProjects (`platform` and `apps`), one Application per platform component, the Application that installs Kyverno policies, the cluster's Karpenter NodePool, and one ApplicationSet. `clusters/base` carries the parts that are identical between clusters. The cluster directory patches in the `values-<cluster>.yaml` file for each component and, in prod, the sync windows.

**Platform.** `platform/<component>` is an Application for an upstream Helm chart, pinned to a chart version, plus a shared `values.yaml` and one `values-<env>.yaml` per environment. Argo CD reads the chart from the upstream repository and the values files from this repository (a multi-source Application with a `$values` ref). Components that need custom resources of their own, such as the cert-manager ClusterIssuers or the External Secrets ClusterSecretStore, keep them in a `resources/` kustomization synced one wave after the chart, so the CRDs exist first.

**Apps.** `apps/<name>/base` is a complete, environment-neutral workload. `apps/<name>/overlays/<env>` sets the namespace, replica counts, resources, hostnames and the image tag. The ApplicationSet in each cluster uses the git directory generator over `apps/*/overlays/<env>`; adding a workload is adding a directory.

**Policies.** `policies/` holds Kyverno ClusterPolicies in Audit mode. They produce PolicyReports and metrics rather than blocking admission, which is the right first step for a small team: see what would fail, fix it, then flip to Enforce per policy.

## Sync order

Argo CD applies the root Application's children in sync waves. Argo CD does not assess health for `Application` resources by default, so `bootstrap/argocd/values.yaml` adds a Lua health check; without it every wave would proceed at once.

| Wave | Applications |
| --- | --- |
| 0 | cert-manager, external-secrets, metrics-server, kyverno, karpenter, argo-rollouts |
| 1 | cert-manager-resources, external-secrets-resources, karpenter-resources, ingress-nginx |
| 2 | external-dns, kube-prometheus-stack-resources |
| 3 | kube-prometheus-stack |
| 4 | kyverno-policies |

Workloads are not part of the waves. Their ServiceMonitor carries `SkipDryRunOnMissingResource=true` so an app can sync on a cluster where the Prometheus CRDs are still arriving.

## Node capacity: Karpenter instead of Cluster Autoscaler

Cluster Autoscaler scales node groups that someone sized in advance: a fixed instance type per group, a minimum and a maximum, and a scan loop that adds one node at a time when pods stay pending. The ceiling is a guess made months earlier, and the instance type rarely matches what the pending pods actually asked for.

Karpenter works from the other end. It reads the pending pods, their requests, their topology and affinity constraints, and launches the cheapest instance that satisfies them, picking from every instance family the NodePool allows and from spot or on-demand capacity. When nodes sit underutilized it consolidates them onto fewer or cheaper instances, and it recycles nodes on a schedule so AMI updates roll through on their own. The only hand-set number left is the CPU and memory limit on the NodePool, which is a spend guardrail, not a capacity plan. The controller itself runs on a small managed node group that Karpenter does not touch, so it cannot remove the node it is running on.

## Progressive delivery on the critical path

A plain Deployment rollout is all or nothing: once the new ReplicaSet is healthy by its probes, it takes all the traffic. Probes say the process is up; they say nothing about whether it is returning errors to real users. For anything that handles money or sits on a login path, that gap is where incidents come from.

In prod, `podinfo` ships as an Argo Rollout with a canary strategy. The new version receives 10 percent of traffic through the ingress controller, then 50 percent, while an AnalysisTemplate queries Prometheus for the canary's HTTP success rate. If success drops below 99 percent, the rollout aborts and the stable version keeps serving before most users ever hit the new code. Dev keeps a plain Deployment, because dev exists to find problems quickly, not to hide them from anyone.
