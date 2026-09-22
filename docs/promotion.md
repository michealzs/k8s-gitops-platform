# Promoting a change from dev to prod

Every change is a pull request against `main`. There are no long-lived environment branches. Dev and prod differ only in which files they read: `values-dev.yaml` versus `values-prod.yaml`, and `overlays/dev` versus `overlays/prod`. A change reaches prod when a pull request touches the prod file.

## Workload change (image tag, replicas, resources)

1. Open a pull request that changes `apps/<name>/overlays/dev/`. For a new release, that is the `newTag` under `images:` in `kustomization.yaml`.
2. CI runs `scripts/validate.sh`, yamllint, kube-linter and actionlint. A reviewer approves. Merge.
3. Argo CD on `dev-eks` picks up the commit within three minutes (or at once through the GitHub webhook) and syncs automatically, with prune and self-heal on.
4. Watch it: `argocd app get podinfo` in dev, the Grafana dashboards, and the `PodinfoHighErrorRate` alert. Leave it running long enough to trust it. For most changes an hour is plenty; for a dependency bump, a day.
5. Open a second pull request that makes the same change in `apps/<name>/overlays/prod/`. The diff should be one or two lines. Link the dev pull request in the description.
6. Merge. The prod ApplicationSet has no automated sync, so the Application shows OutOfSync and waits.
7. Inside the sync window (Monday to Friday, 09:00 to 17:00 UTC), someone runs `argocd app sync podinfo`. The Rollout starts the canary: 10 percent of traffic, a two minute pause, 50 percent, a five minute pause, then analysis. Any failed measurement aborts it and the stable ReplicaSet keeps serving.
8. Confirm with `kubectl argo rollouts get rollout podinfo -n podinfo`. If it aborted, see the runbook; the fix is a new pull request, not a hand edit.

## Platform value change (a setting in a values file)

Same flow. Edit `platform/<component>/values-dev.yaml`, merge, observe, then edit `values-prod.yaml`. Platform Applications sync automatically in both clusters. Prod denies automated syncs on weekends, so a Friday evening merge lands on Monday unless an operator syncs it by hand.

A change to the shared `values.yaml` reaches both clusters in one merge. Keep those changes small and boring. Anything you would want to watch in dev first belongs in `values-dev.yaml` until it has proven itself, then moves into `values.yaml` in a follow-up.

## Chart version bump

The chart version is pinned once, in `platform/<component>/application.yaml`, and applies to both clusters. To run a newer chart in dev first, add a patch to `clusters/dev/kustomization.yaml`:

```yaml
  - target:
      kind: Application
      name: cert-manager
    patch: |-
      - op: replace
        path: /spec/sources/0/targetRevision
        value: v1.22.0
```

Merge, let dev run on it, then open the promotion pull request: move the new version into `application.yaml` and delete the patch. The dev cluster sees no change; prod upgrades. Read the chart's release notes before the first pull request, not the second. CRD changes in particular need `ServerSideApply=true`, which every platform Application already sets.

## Rolling back

Git is the rollback path. Revert the pull request, merge, sync. `argocd app rollback` exists for emergencies and is documented in the runbook, but a cluster that has been rolled back with it no longer matches `main`, and self-heal will move it forward again in dev. Revert in git first, then roll back the cluster if you cannot wait for the sync.

## What a reviewer checks

- CI is green. The rendered diff in the kube-linter job is what will be applied; read it.
- A prod pull request references the dev pull request it promotes, and the dev change has been running.
- No secrets, no hand-written hostnames outside the overlay, no `latest` tags.
- Chart bumps link the upstream release notes and mention any CRD or values changes.
