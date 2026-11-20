# vllm-k8s-serving-lab

[English](README.md) | [Español](README.es.md)

vLLM Stack on a local kind cluster, serving `Qwen/Qwen2.5-0.5B-Instruct` with two replicas behind a router, prefix-aware or kv-cache-aware routing and Prometheus/Grafana for monitoring.

Everything runs on one AMD GPU (In my case I used my RX 7600, 8 GB, `gfx1102`, ROCm).

```
client ──► router ──┬─► vLLM replica 1 ─┐
                    └─► vLLM replica 2 ─┴─► one GPU, shared through a DRA claim
```

## What runs here

- **VLLM.** The `vllm-stack` chart deploys the router and the vLLM replicas. Both images are pinned: `lmcache/lmstack-router:v0.1.14` and `vllm/vllm-openai-rocm:v0.33.0`.
- **GPU.** The ROCm DRA driver publishes the card as a `ResourceSlice`; pods request it with a `ResourceClaim`. The device plugin can only hand a whole GPU to one pod, so it was not an option.
- **Chart patch.** `vllm-stack` has no field for `resourceClaims`, so `helm/postrender-dra` is a Helm 4 post-renderer that adds the claim to the rendered manifests with kustomize. It is used on every install and upgrade, and the chart stays official.
- **Model volume.** A PVC named `vllm-models` holds the Hugging Face files and the `torch.compile` cache, so a restart loads the model in about 2 seconds.
- **Monitoring.** `kube-prometheus-stack` scrapes the router and the replicas every 30 seconds, and Grafana loads the dashboards the vLLM chart creates.

The cluster keeps two node pools: `vllm-lab-worker` carries `pool=gpu` and the taint `pool=gpu:NoSchedule`, and hosts vLLM and the DRA driver. `vllm-lab-worker2` carries `pool=cpu`, and the router, Prometheus and Grafana land there.

## Repo layout

```
charts/            wrapper charts
helm/              charts values + the post-renderer
infra/             kind cluster, namespaces, the model PVC, the GPU claim and a GPU smoke test
scripts/           prefix-load.sh (load generator) and validate.sh (the checks CI runs)
```

Each wrapper pins its dependency in `Chart.lock` and keeps the `.tgz` in `charts/`.

## Deploying

You need Docker with the `amdgpu` driver on the host, `kind` 0.33+, `kubectl` 1.37+ and `helm` 4, plus 8 GB of VRAM and about 15 GB of free disk. The host does not need ROCm installed: it runs inside the containers.

```bash
kind create cluster --config infra/kind/cluster.yaml
docker exec vllm-lab-worker mkdir -p /etc/cdi
kubectl apply -f infra/namespaces.yaml

helm upgrade --install k8s-gpu-dra-driver charts/dra-driver -n kube-amd-gpu --create-namespace
kubectl apply -f infra/amd-gpu/vllm-gpu-claim.yaml
kubectl apply -f infra/vllm-models.yaml

kind load docker-image vllm/vllm-openai-rocm:v0.33.0 --name vllm-lab --nodes vllm-lab-worker
helm plugin install helm/postrender-dra

helm upgrade --install vllm charts/vllm -n vllm \
  -f helm/values-minimal.yaml --post-renderer vllm-dra
```

`/etc/cdi` has to exist before the DRA driver starts, because that is where it writes the claim specifications, and `/var/run` would be wiped by a node restart. Loading the image into the node avoids downloading 18 GB again.

`--post-renderer vllm-dra` is not optional: without it the pods start with no GPU.

For monitoring, the Grafana admin password comes from a Secret that is not in the repository:

```bash
read -rs -p 'Grafana password: ' GF_PASS; echo
kubectl create secret generic grafana-admin -n monitoring \
  --from-literal=admin-user=admin --from-literal=admin-password="$GF_PASS"
unset GF_PASS

helm upgrade --install kube-prom-stack charts/monitoring -n monitoring
```

## Sending requests

Everything goes through the router, which speaks the OpenAI API:

```bash
kubectl port-forward -n vllm svc/vllm-router-service 30080:80

curl -s localhost:30080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"What is the capital of France?"}],"max_tokens":50}' \
  | jq -r '.choices[0].message.content'
```

`scripts/prefix-load.sh` sends 50 completions and reports the cache hit rate of that run, reading the replica metrics before and after:

```
requests: 50 (failed: 0)
prefix cache: 1984 of 3150 prompt tokens reused (63.0% hit rate)
```

## Monitoring

Grafana runs on http://localhost:8080 after `kubectl port-forward -n monitoring svc/kube-prom-stack-grafana 8080:80`.

The vLLM dashboard shows latency, throughput, KV cache usage and the prefix cache hit rate.

## Configurations

The three values files are alternative setups of the same release, applied with the command above.

| Values | Replicas | Routing |
| --- | --- | --- |
| `values-minimal.yaml` | 1 | `roundrobin`, 80% of the GPU memory |
| `values-prefix-aware.yaml` | 2 | `prefixaware`, 40% each |
| `values-kv-aware.yaml` | 2 | `kvaware`, 40% each |

Going from one replica to two means scaling vLLM to zero first, since the existing pod holds 80% of the memory: `kubectl scale deployment vllm-qwen05b-deployment-vllm -n vllm --replicas=0`.

The KV-aware file goes through LMCache instead. It needs a GPU with LMCache kernels (`gfx942`, `gfx950` or CUDA).

Two settings exist only because of the hardware. `HSA_OVERRIDE_GFX_VERSION=11.0.0` makes this GPU run the image's `gfx1100` kernels, since `gfx1102` is not compiled in. And two replicas on one device need `gpuMemoryUtilization: 0.4` with `maxSurge: 0`, so the old pod releases memory before the new one starts.

## Checks

```bash
./scripts/validate.sh
```

yamllint, `helm lint` on every chart and configuration, `helm template` of all three releases with the post-renderer, and `kubeconform -strict` against the Kubernetes 1.37 schemas and a pinned CRD catalog.

The `validate` workflow runs the same script on every pull request and on pushes to `main`.

## References

- [vLLM Production Stack](https://github.com/vllm-project/production-stack)
- [ROCm DRA driver](https://github.com/ROCm/k8s-gpu-dra-driver)
- [Dynamic Resource Allocation](https://kubernetes.io/docs/concepts/resource-management/dynamic-resource-allocation/)
- [kind](https://kind.sigs.k8s.io/)
