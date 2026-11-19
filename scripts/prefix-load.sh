#!/usr/bin/env bash
# Sends a batch of completions through the router and reports the vLLM prefix cache hit rate.
# Requires: kubectl port-forward -n vllm svc/vllm-router-service 30080:80
set -euo pipefail

URL="${URL:-http://localhost:30080}"
MODEL="${MODEL:-Qwen/Qwen2.5-0.5B-Instruct}"
TOTAL="${TOTAL:-50}"
NAMESPACE="${NAMESPACE:-vllm}"

prefix_names=(geography code-review support)
prefixes=(
  "You are a helpful geography assistant. Answer questions about European countries with short, factual answers. Use the metric system, mention official sources when relevant, and keep each answer under three sentences. Do not invent statistics; if you are not sure about a number, say that it is an estimate. "
  "You are a strict code reviewer for Python projects. Point out bugs, unsafe patterns and missing tests. Prefer the standard library over third-party packages, follow PEP 8, and explain every finding in one sentence. Never rewrite the whole file; suggest the smallest change that fixes each problem. "
  "You are the support assistant of an online store. Be polite and brief, never promise refunds or delivery dates, and point customers to the help center when you cannot solve the problem. Ask for the order number before discussing any specific purchase, and never ask for passwords or card numbers. "
)
questions=(
  "What is the capital of France?"
  "Which rivers flow through Germany?"
  "How do I reset my password?"
  "Review this code: def add(a, b): return a - b"
  "Where can I see my invoices?"
  "What is the population of Spain?"
  "Review this code: import os; os.system(input())"
  "Can I change the delivery address of my order?"
)

prefix_cache_totals() {
  local pod queries=0 hits=0 q h
  for pod in $(kubectl get pods -n "$NAMESPACE" -l model -o name); do
    read -r q h < <(kubectl exec -n "$NAMESPACE" "$pod" -- curl -s localhost:8000/metrics \
      | awk '/^vllm:prefix_cache_queries_total/ {q += $NF} /^vllm:prefix_cache_hits_total/ {h += $NF} END {print q + 0, h + 0}')
    queries=$(awk -v a="$queries" -v b="$q" 'BEGIN {print a + b}')
    hits=$(awk -v a="$hits" -v b="$h" 'BEGIN {print a + b}')
  done
  echo "$queries $hits"
}

if ! curl -sf -o /dev/null "$URL/v1/models"; then
  echo "error: router not reachable at $URL; start: kubectl port-forward -n $NAMESPACE svc/vllm-router-service 30080:80" >&2
  exit 1
fi

read -r queries_before hits_before < <(prefix_cache_totals)

failures=0
for i in $(seq 1 "$TOTAL"); do
  if (( i % 5 == 0 )); then
    label="unique"
    prompt="Tell me one short fact about the number $i and the color number $RANDOM."
  else
    p=$(( i % ${#prefixes[@]} ))
    label="${prefix_names[$p]}"
    prompt="${prefixes[$p]}${questions[$(( i % ${#questions[@]} ))]}"
  fi

  body=$(jq -n --arg model "$MODEL" --arg prompt "$prompt" \
    '{model: $model, prompt: $prompt, max_tokens: 32}')
  result=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' \
    -H 'Content-Type: application/json' -d "$body" "$URL/v1/completions" || echo "000 0")
  read -r code seconds <<< "$result"
  [[ "$code" == "200" ]] || failures=$(( failures + 1 ))
  printf '%3d  %-12s  HTTP %s  %ss\n' "$i" "$label" "$code" "$seconds"
done

read -r queries_after hits_after < <(prefix_cache_totals)

awk -v q="$(( ${queries_after%.*} - ${queries_before%.*} ))" \
    -v h="$(( ${hits_after%.*} - ${hits_before%.*} ))" \
    -v f="$failures" -v n="$TOTAL" 'BEGIN {
  printf "\nrequests: %d (failed: %d)\n", n, f
  printf "prefix cache: %d of %d prompt tokens reused", h, q
  if (q > 0) printf " (%.1f%% hit rate)", 100 * h / q
  printf "\n"
}'
