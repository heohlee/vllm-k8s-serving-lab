#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

kubernetes_version=1.37.0
crds_catalog_ref=784ec895547a36e548e6810b41f27baade3a0890
crds_catalog_url="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${crds_catalog_ref}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
scenarios=(minimal kv-aware prefix-aware)
infra_manifests=(infra/*.yaml infra/amd-gpu/*.yaml)
failures=()

for tool in helm kubectl kubeconform yamllint; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'error: %s not found on PATH\n' "$tool" >&2
    exit 1
  fi
done

if ! helm plugin list | awk 'NR > 1 { print $1 }' | grep -qx vllm-dra; then
  printf 'error: helm plugin vllm-dra not installed\nrun: helm plugin install helm/postrender-dra\n' >&2
  exit 1
fi

run_step() {
  local name=$1
  shift
  printf '\n==> %s\n' "$name"
  if ! "$@"; then
    failures+=("$name")
    printf 'FAILED: %s\n' "$name" >&2
  fi
}

check_yaml_syntax() {
  yamllint --strict .
}

lint_vllm() {
  local scenario=$1
  helm lint charts/vllm -f "helm/values-${scenario}.yaml"
}

render_dir=$(mktemp -d)
trap 'rm -rf "$render_dir"' EXIT

render_vllm() {
  local scenario=$1
  local out="$render_dir/vllm-${scenario}.yaml"
  if ! helm template vllm charts/vllm -n vllm -f "helm/values-${scenario}.yaml" \
    --post-renderer vllm-dra >"$out"; then
    return 1
  fi
  if ! grep -q 'resourceClaims:' "$out"; then
    printf 'error: post-renderer patch not applied to %s\n' "$out" >&2
    return 1
  fi
  printf '%s: %s objects\n' "vllm-${scenario}" "$(grep -c '^kind:' "$out")"
}

render_chart() {
  local release=$1 chart=$2 namespace=$3
  local out="$render_dir/${release}.yaml"
  if ! helm template "$release" "$chart" -n "$namespace" >"$out"; then
    return 1
  fi
  printf '%s: %s objects\n' "$release" "$(grep -c '^kind:' "$out")"
}

check_schemas() {
  kubeconform -strict -summary \
    -kubernetes-version "$kubernetes_version" \
    -schema-location default \
    -schema-location "$crds_catalog_url" \
    "$render_dir"/*.yaml "${infra_manifests[@]}"
}

run_step "yamllint" check_yaml_syntax

for scenario in "${scenarios[@]}"; do
  run_step "helm lint vllm (${scenario})" lint_vllm "$scenario"
done
run_step "helm lint monitoring" helm lint charts/monitoring
run_step "helm lint dra-driver" helm lint charts/dra-driver

for scenario in "${scenarios[@]}"; do
  run_step "helm template vllm (${scenario})" render_vllm "$scenario"
done
run_step "helm template kube-prom-stack" render_chart kube-prom-stack charts/monitoring monitoring
run_step "helm template k8s-gpu-dra-driver" render_chart k8s-gpu-dra-driver charts/dra-driver kube-amd-gpu

run_step "kubeconform" check_schemas

if (( ${#failures[@]} > 0 )); then
  printf '\n%d check(s) failed:\n' "${#failures[@]}" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

printf '\nall checks passed\n'
