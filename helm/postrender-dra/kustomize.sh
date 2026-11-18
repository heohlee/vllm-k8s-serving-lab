#!/usr/bin/env sh
set -e
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cp "${HELM_PLUGIN_DIR}/kustomization.yaml" "$dir/"
cat > "$dir/all.yaml"
kubectl kustomize "$dir"
