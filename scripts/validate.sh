#!/usr/bin/env bash
#
# Render every buildable kustomization in this repository and validate the
# output with kubeconform. CI runs this exact script; run it locally before
# opening a pull request.
#
# Usage:
#   scripts/validate.sh
#   RENDER_DIR=rendered scripts/validate.sh   # keep the rendered YAML for kube-linter or review
#
# Environment:
#   RENDER_DIR           directory to keep rendered manifests in (default: a temp dir, removed on exit)
#   KUBERNETES_VERSION   Kubernetes version used for the core schemas (default: 1.33.0)
#
# Requires kustomize and kubeconform on PATH.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.33.0}"
CRD_CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
SCHEMA_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/kubeconform"

for tool in kustomize kubeconform; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is not on PATH" >&2
    exit 1
  fi
done

if [ -n "${RENDER_DIR:-}" ]; then
  render_dir="$RENDER_DIR"
  keep_render_dir=1
else
  render_dir="$(mktemp -d)"
  keep_render_dir=0
fi
mkdir -p "$render_dir" "$SCHEMA_CACHE"

cleanup() {
  if [ "$keep_render_dir" -eq 0 ]; then
    rm -rf "$render_dir"
  fi
}
trap cleanup EXIT

# Kustomization roots that are meant to be built on their own. Directories
# that only exist to be included by an overlay (apps/*/base, clusters/base)
# are not listed here.
targets=""
for dir in \
  bootstrap/*/ \
  clusters/*/ \
  apps/*/overlays/*/ \
  platform/*/resources/ \
  platform/*/resources/*/ \
  policies/; do
  dir="${dir%/}"
  case "$dir" in
    clusters/base) continue ;;
  esac
  if [ -f "$REPO_ROOT/$dir/kustomization.yaml" ]; then
    targets="$targets $dir"
  fi
done

if [ -z "$targets" ]; then
  echo "error: no kustomization roots found under $REPO_ROOT" >&2
  exit 1
fi

failed=0
built=0
for target in $targets; do
  built=$((built + 1))
  out="$render_dir/${target//\//_}.yaml"
  echo "==> $target"

  if ! kustomize build "$REPO_ROOT/$target" > "$out"; then
    echo "    kustomize build failed for $target" >&2
    failed=1
    continue
  fi

  if ! kubeconform \
    -strict \
    -summary \
    -ignore-missing-schemas \
    -kubernetes-version "$KUBERNETES_VERSION" \
    -schema-location default \
    -schema-location "$CRD_CATALOG" \
    -cache "$SCHEMA_CACHE" \
    "$out"; then
    failed=1
  fi
done

echo
if [ "$failed" -ne 0 ]; then
  echo "validation failed (built $built kustomizations)" >&2
  exit 1
fi
echo "validation passed ($built kustomizations rendered and checked)"
if [ "$keep_render_dir" -eq 1 ]; then
  echo "rendered manifests kept in $render_dir"
fi
