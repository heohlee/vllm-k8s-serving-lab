# vllm-k8s-serving-lab

[English](README.md) | [Español](README.es.md)

vLLM Stack en un cluster local de kind, sirviendo `Qwen/Qwen2.5-0.5B-Instruct` con dos réplicas detrás de un router, routing por prefijo o por KV cache, y Prometheus/Grafana para monitoreo.

Todo corre en una GPU AMD (en mi caso mi RX 7600, 8 GB, `gfx1102`, ROCm).

```
cliente ──► router ──┬─► réplica vLLM 1 ─┐
                     └─► réplica vLLM 2 ─┴─► una GPU, compartida con un claim DRA
```

## Qué corre acá

- **VLLM.** El chart `vllm-stack` despliega el router y las réplicas de vLLM. Las dos imágenes están fijadas: `lmcache/lmstack-router:v0.1.14` y `vllm/vllm-openai-rocm:v0.33.0`.
- **GPU.** El driver DRA de ROCm publica la placa como un `ResourceSlice`; los pods la piden con un `ResourceClaim`. El device plugin solo puede entregar una GPU entera a un pod, así que no era una opción.
- **Parche al chart.** `vllm-stack` no tiene un campo para `resourceClaims`, así que `helm/postrender-dra` es un post-renderer de Helm 4 que le agrega el claim a los manifiestos renderizados con kustomize. Se usa en cada install y upgrade, y el chart sigue siendo el oficial.
- **Volumen del modelo.** Un PVC llamado `vllm-models` guarda los archivos de Hugging Face y el cache de `torch.compile`, así un reinicio carga el modelo en unos 2 segundos.
- **Monitoreo.** `kube-prometheus-stack` scrapea el router y las réplicas cada 30 segundos, y Grafana carga los dashboards que crea el chart de vLLM.

El cluster tiene dos pools de nodos: `vllm-lab-worker` lleva `pool=gpu` y el taint `pool=gpu:NoSchedule`, y aloja a vLLM y al driver DRA. `vllm-lab-worker2` lleva `pool=cpu`, y ahí caen el router, Prometheus y Grafana.

## Estructura

```
charts/            wrapper charts
helm/              values de los charts + el post-renderer
infra/             cluster de kind, namespaces, PVC del modelo, claim de GPU y smoke test de la GPU
scripts/           prefix-load.sh (generador de carga) y validate.sh (las verificaciones del CI)
```

Cada wrapper fija su dependencia en `Chart.lock` y guarda el `.tgz` en `charts/`, así instalar no necesita `helm repo add` ni acceso de red a los repositorios de charts.

## Desplegar

Necesitás Docker con el driver `amdgpu` en el host, `kind` 0.33+, `kubectl` 1.37+ y `helm` 4, más 8 GB de VRAM y unos 15 GB de disco libre. El host no necesita ROCm instalado: corre dentro de los contenedores.

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

`/etc/cdi` tiene que existir antes de que arranque el driver DRA, porque ahí escribe las especificaciones de los claims, y `/var/run` se borraría al reiniciar el nodo. Cargar la imagen en el nodo evita bajar 18 GB de nuevo.

`--post-renderer vllm-dra` no es opcional: sin eso los pods arrancan sin GPU.

Para el monitoreo, la contraseña de admin de Grafana sale de un Secret que no está en el repositorio:

```bash
read -rs -p 'Grafana password: ' GF_PASS; echo
kubectl create secret generic grafana-admin -n monitoring \
  --from-literal=admin-user=admin --from-literal=admin-password="$GF_PASS"
unset GF_PASS

helm upgrade --install kube-prom-stack charts/monitoring -n monitoring
```

## Mandar requests

Todo pasa por el router, que habla la API de OpenAI:

```bash
kubectl port-forward -n vllm svc/vllm-router-service 30080:80

curl -s localhost:30080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"¿Cuál es la capital de Francia?"}],"max_tokens":50}' \
  | jq -r '.choices[0].message.content'
```

`scripts/prefix-load.sh` manda 50 completions y reporta el hit rate del cache de esa corrida, leyendo las métricas de las réplicas antes y después:

```
requests: 50 (failed: 0)
prefix cache: 1984 of 3150 prompt tokens reused (63.0% hit rate)
```

## Monitoreo

Grafana queda en http://localhost:8080 después de `kubectl port-forward -n monitoring svc/kube-prom-stack-grafana 8080:80`.

El dashboard de vLLM muestra latencia, throughput, uso del KV cache y el hit rate del prefix cache.

## Configuraciones

Los tres archivos de values son configuraciones alternativas del mismo release, y se aplican con el comando de arriba.

| Values | Réplicas | Routing |
| --- | --- | --- |
| `values-minimal.yaml` | 1 | `roundrobin`, 80% de la memoria de la GPU |
| `values-prefix-aware.yaml` | 2 | `prefixaware`, 40% cada una |
| `values-kv-aware.yaml` | 2 | `kvaware`, 40% cada una |

Pasar de una réplica a dos implica bajar vLLM a cero primero, porque el pod existente ocupa el 80% de la memoria: `kubectl scale deployment vllm-qwen05b-deployment-vllm -n vllm --replicas=0`.

El archivo KV-aware pasa por LMCache. Necesita una GPU con kernels de LMCache (`gfx942`, `gfx950` o CUDA).

`HSA_OVERRIDE_GFX_VERSION=11.0.0` hace que esta GPU corra los kernels `gfx1100` de la imagen, porque `gfx1102` no está compilado. Y dos réplicas en un solo dispositivo necesitan `gpuMemoryUtilization: 0.4` con `maxSurge: 0`, para que el pod viejo libere memoria antes de que arranque el nuevo.

## Verificaciones

```bash
./scripts/validate.sh
```

yamllint, `helm lint` sobre cada chart y configuración, `helm template` de los tres releases con el post-renderer, y `kubeconform -strict` contra los esquemas de Kubernetes 1.37 y un catálogo de CRDs fijado.

El workflow `validate` corre el mismo script en cada pull request y en los push a `main`.

## Referencias

- [vLLM Production Stack](https://github.com/vllm-project/production-stack)
- [Driver DRA de ROCm](https://github.com/ROCm/k8s-gpu-dra-driver)
- [Dynamic Resource Allocation](https://kubernetes.io/docs/concepts/resource-management/dynamic-resource-allocation/)
- [kind](https://kind.sigs.k8s.io/)
