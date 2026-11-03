#!/usr/bin/env bash
# Runs INSIDE the CT. One deterministic /api/generate call; prints:
#   eval_count eval_ns prompt_count prompt_ns load_ns      or   ERR <message>
# Usage: ollama-bench.sh <model> <num_gpu|auto> <num_predict> [api host:port]
#        ollama-bench.sh --unload <model> [api]
set -uo pipefail
if [[ ${1:-} == --unload ]]; then
  API=${3:-127.0.0.1:11434}
  curl -fsS --max-time 60 "http://$API/api/generate" -d "$(jq -nc --arg m "$2" '{model:$m,keep_alive:0}')" >/dev/null
  exit $?
fi
M=$1; NG=${2:-auto}; NP=${3:-128}; API=${4:-127.0.0.1:11434}
P="Explain in technical detail how TCP congestion control works: slow start, congestion avoidance, fast retransmit, fast recovery, and how CUBIC differs from Reno."
OPTS=$(jq -nc --argjson np "$NP" --arg ng "$NG" \
  '{num_predict:$np,temperature:0,seed:42} + (if $ng=="auto" then {} else {num_gpu:($ng|tonumber)} end)')
REQ=$(jq -nc --arg m "$M" --arg p "$P" --argjson o "$OPTS" '{model:$m,prompt:$p,stream:false,options:$o}')
R=$(curl -sS --max-time 1800 "http://$API/api/generate" -d "$REQ") || { echo "ERR request to $API failed"; exit 1; }
jq -r 'if .error then "ERR \(.error)" else "\(.eval_count) \(.eval_duration) \(.prompt_eval_count // 0) \(.prompt_eval_duration // 0) \(.load_duration // 0)" end' <<<"$R"
