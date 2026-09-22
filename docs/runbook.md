# Runbook

Day-to-day operations for the clusters managed from this repository. Every command assumes a kubeconfig for the cluster in question and the `argocd` CLI logged in.

## Log in

```sh
# Argo CD is behind ingress-nginx with a Let's Encrypt certificate. Use SSO;
# the local admin account is for bootstrap and break glass only.
argocd login argocd.example.com --sso

# Without ingress (bootstrap, or ingress-nginx is down):
kubectl -n argocd port-forward svc/argocd-server 8080:80
argocd login localhost:8080 --plaintext --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
```

## Inspect

```sh
argocd app list                                  # every Application, sync and health status
argocd app get podinfo                           # resources, conditions, last sync
argocd app diff podinfo                          # live cluster versus git, exit code 1 means drift
argocd app history podinfo                       # deployed revisions with ids
argocd app resources podinfo                     # the objects Argo CD is tracking
argocd appset get apps                           # which directories the ApplicationSet has found
kubectl -n argocd get applications.argoproj.io   # the same, from the API
```

## Sync

```sh
argocd app sync podinfo                          # sync now (prod apps have no automated sync)
argocd app sync podinfo --dry-run                # show what would change
argocd app sync podinfo --prune                  # also delete resources no longer in git
argocd app sync root-prod                        # re-render clusters/prod and reconcile the app-of-apps
argocd app wait podinfo --health --timeout 600   # block until healthy
```

Sync waves mean `root-prod` waits for each wave to be healthy before starting the next. If a platform Application is stuck, `root-prod` stays Progressing; fix the child, not the root.

## Canary rollouts (prod workloads)

```sh
kubectl argo rollouts get rollout podinfo -n podinfo --watch   # live view of steps, weights, analysis
kubectl argo rollouts promote podinfo -n podinfo               # skip the current pause
kubectl argo rollouts promote podinfo -n podinfo --full        # skip every remaining step
kubectl argo rollouts abort podinfo -n podinfo                 # send all traffic back to stable
kubectl argo rollouts undo podinfo -n podinfo                  # roll the Rollout back to the previous revision
kubectl get analysisrun -n podinfo                             # the measurements behind an abort
```

An aborted Rollout stays Degraded until the next sync. The correct fix is a revert pull request; syncing it starts a fresh canary with the old image.

## Roll back

```sh
argocd app history podinfo
argocd app rollback podinfo <ID>                 # redeploy the manifests from that revision
```

Rollback disables automated sync on that Application so self-heal does not immediately undo it. Revert the change in git, merge, then re-enable:

```sh
argocd app set podinfo --sync-policy automated --self-heal --auto-prune   # dev only; prod stays manual
```

## Break glass

Order of preference, least invasive first.

**1. Sync outside the prod window.** The windows on the `apps` and `platform` projects set `manualSync: true`. A plain `argocd app sync <app>` works at any time; only automated syncs wait. Say why in the incident channel.

**2. Stop Argo CD from touching one Application.**

```sh
argocd app set kube-prometheus-stack --sync-policy none
```

Now `kubectl` edits stick. Everything else is still reconciled. Restore with the `argocd app set ... --sync-policy automated --self-heal --auto-prune` from above, after the fix is in git.

**3. Pause a whole cluster.** Scale the application controller to zero. Nothing reconciles until it is scaled back.

```sh
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
# ... make the change, get the cluster stable ...
kubectl -n argocd scale statefulset argocd-application-controller --replicas=1
```

**4. Argo CD is down and cannot be fixed quickly.** Render and apply from git directly. The output is identical to what Argo CD would apply.

```sh
kustomize build apps/podinfo/overlays/prod | kubectl apply --server-side -f -
```

Whichever step you used, the incident is not closed until the cluster matches `main` again: `argocd app diff` is clean for every Application and no sync policy was left at `none`.

## Common problems

| Symptom | Likely cause | Action |
| --- | --- | --- |
| Application OutOfSync but `argocd app diff` shows only `caBundle` | Webhook certificate injected in-cluster | Already ignored for kube-prometheus-stack; add an `ignoreDifferences` entry for any new chart that does this |
| `root-prod` Progressing for a long time | A child Application in an early wave is not Healthy | `argocd app list` sorted by health, fix the child |
| ServiceMonitor fails to sync with "no matches for kind" | Prometheus CRDs not installed yet | Sync `kube-prometheus-stack`, then retry; the annotation on the ServiceMonitor skips the dry run but not the apply |
| ExternalSecret not Ready | IAM role missing or the secret path does not exist | `kubectl describe externalsecret <name>`; the message names the missing permission or key |
| Pods pending, no new nodes | NodePool at its CPU limit, or subnets and security groups not tagged for discovery | `kubectl get nodepool general -o yaml` and check `status.resources` against `spec.limits`; `kubectl describe nodeclaim` shows launch errors |
| Certificate stuck in Pending | HTTP-01 challenge not reachable | `kubectl get challenge -A`; DNS must resolve to the ingress load balancer first |
| Rollout Degraded | Analysis failed or manual abort | `kubectl get analysisrun -n <ns>` for the measurements, then revert in git |

## Bootstrap a fresh cluster

Covered step by step in the README under "Bootstrap a cluster". The short form: `helm install` Argo CD with `bootstrap/argocd/values.yaml`, then `kubectl apply -k bootstrap/<cluster>`.
