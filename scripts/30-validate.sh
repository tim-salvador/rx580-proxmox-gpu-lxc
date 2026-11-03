#!/usr/bin/env bash
# End-to-end validation for AMD Radeon -> LXC -> Ollama (Vulkan):
# host GPU health, CT device wiring + GID, Vulkan as root and as the ollama user, Ollama backend
# discovery, then a GPU vs CPU benchmark with host-side proof (gpu_busy_percent + VRAM delta).
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")" && source ./lib.sh
usage() { cat <<EOF2
Usage: $0 -c <ctid> [-m model] [-M multi_gpu_model] [-B] [-s]
  -m  benchmark model (default llama3.2:3b)
  -M  larger model to prove a split across all passed GPUs (e.g. a 12-14B Q4 > 8 GiB)
  -B  skip benchmarks (wiring checks only)
  -s  start CT if stopped
EOF2
exit 2; }
CT=; MODEL=llama3.2:3b; MULTI=; BENCH=1; START=0
while getopts ':c:m:M:Bsh' o; do
  case $o in c) CT=$OPTARG;; m) MODEL=$OPTARG;; M) MULTI=$OPTARG;; B) BENCH=0;; s) START=1;; *) usage;; esac
done
[[ $CT =~ ^[0-9]+$ ]] || usage
need_root; need_pve
CONF=/etc/pve/lxc/$CT.conf; [[ -f $CONF ]] || die "no $CONF"
X() { pct exec "$CT" -- "$@"; }

hdr "CT $CT config"
MAIN=$(ct_main_conf "$CT")
DEVS=$(grep -E '^dev[0-9]+: /dev/dri/' <<<"$MAIN" || true)
[[ -n $DEVS ]] && echo "$DEVS" | indent || { fail "no /dev/dri devN entries (run 10-lxc-gpu.sh)"; summary; exit 1; }
GPUS=()
while read -r line; do
  node=$(awk '{print $2}' <<<"$line" | cut -d, -f1)
  [[ $node == /dev/dri/renderD* ]] || continue
  b=$(render_bdf "$node")
  [[ -n $b ]] && { GPUS+=("$b"); pass "$node -> $b ($(pci_name "$b"))"; } || fail "$node: no such render node on host now (renumbered?)"
done <<<"$DEVS"
(( ${#GPUS[@]} )) || { fail "no render nodes passed"; summary; exit 1; }
grep -qE '^lxc\..*(dri|226:)' <<<"$MAIN" && warn "raw lxc.* DRI lines also present (double wiring)"

hdr "Host GPU health"
for g in "${GPUS[@]}"; do
  [[ $(pci_driver "$g") == amdgpu ]] && pass "$g amdgpu" || fail "$g driver: $(pci_driver "$g")"
  info "$g VRAM $(vram_used "$g")/$(vram_total "$g") MiB, busy $(gpu_busy "$g")%, $(gpu_temp "$g")C, $(gpu_power "$g")W"
done
E=$(journalctl -k -b --no-pager 2>/dev/null | grep -iE 'amdgpu.*(ring .* timeout|gpu reset|hang|page fault)' || true)
[[ -z $E ]] && pass "no amdgpu ring timeouts / resets this boot" || { fail "amdgpu faults this boot:"; echo "$E" | tail -8 | indent; }

hdr "CT $CT runtime"
ST=$(pct status "$CT" | awk '{print $2}')
if [[ $ST != running ]]; then
  (( START )) || { fail "CT is $ST (use -s)"; summary; exit 1; }
  pct start "$CT" || { fail "pct start failed: lxc-start -n $CT -F -l DEBUG -o /tmp/lxc-$CT.log"; summary; exit 1; }
  sleep 8
fi
X sh -c 'ls -l /dev/dri/' | indent
CGID=$(X getent group render | cut -d: -f3)
for line in $(grep -oE '/dev/dri/renderD[0-9]+[^ ]*' <<<"$DEVS"); do
  n=${line%%,*}; want=$(sed -n 's/.*gid=\([0-9]*\).*/\1/p' <<<"$line")
  have=$(X stat -c %g "$n" 2>/dev/null || echo missing)
  [[ $have == "$CGID" ]] && pass "$n group = render ($CGID)" || fail "$n gid in CT: $have, render GID: ${CGID:-none}, configured gid=${want:-none}"
done
if X sh -c 'command -v vulkaninfo' >/dev/null 2>&1; then
  for who in root ollama; do
    if [[ $who == root ]]; then VK=$(X vulkaninfo --summary 2>&1); else VK=$(X runuser -u ollama -- vulkaninfo --summary 2>&1); fi
    N=$(grep -c 'deviceName.*RADV' <<<"$VK" || true)
    (( N == ${#GPUS[@]} )) && pass "Vulkan as $who: $N RADV device(s)" || fail "Vulkan as $who: $N RADV device(s), expected ${#GPUS[@]}"
    grep -E 'deviceName' <<<"$VK" | indent
  done
else warn "vulkaninfo not in CT (run 20-ct-ollama.sh)"; fi

hdr "Ollama"
# pct exec does not reliably include /usr/local/bin in PATH: always use the absolute path
OLL=/usr/local/bin/ollama
info "pct exec PATH: $(X sh -c 'echo $PATH')"
if ! X test -x "$OLL"; then fail "$OLL not present in CT"; summary; exit 1; fi
X systemctl is-active --quiet ollama && pass "ollama.service active" || fail "ollama.service not active"
info "$(X "$OLL" --version 2>&1 | tail -1)"
X test -f /usr/local/lib/ollama/vulkan/libggml-vulkan.so && pass "Vulkan backend library present" || fail "libggml-vulkan.so missing"
info "file caps: $(X getcap /usr/local/bin/ollama 2>/dev/null || echo none)"
info "service env: $(X systemctl show ollama -p Environment --value)"
# only the currently running server process (earlier restarts also log discovery lines)
MPID=$(X systemctl show ollama -p MainPID --value)
LOGS=$(X journalctl -u ollama -b --no-pager 2>/dev/null | grep -F "ollama[$MPID]")
IC=$(grep -i 'inference compute' <<<"$LOGS")
info "server PID $MPID"
echo "$IC" | indent
NV=$(grep -ci 'inference compute.*vulkan' <<<"$IC" || true)
(( NV >= ${#GPUS[@]} )) && pass "Ollama discovered $NV Vulkan GPU(s)" || fail "Ollama discovered $NV Vulkan GPU(s), expected ${#GPUS[@]}"
grep -qiE 'llvmpipe|lavapipe' <<<"$IC" && warn "Ollama enumerated llvmpipe as a GPU: set GGML_VK_VISIBLE_DEVICES to the RADV indices"
grep -qi 'available=' <<<"$IC" && info "compare available= vs total= above: equal values usually mean Ollama is estimating VRAM (no cap_perfmon effect)"

(( BENCH )) || { summary; exit $?; }

# API endpoint as the service sees it
H=$(X systemctl show ollama -p Environment --value | tr ' ' '\n' | sed -n 's/^OLLAMA_HOST=//p')
H=${H#http://}; [[ -z $H ]] && H=127.0.0.1:11434
[[ $H == 0.0.0.0:* || $H == :* ]] && H=127.0.0.1:${H##*:}
[[ $H == *:* ]] || H=$H:11434
info "API: $H"
pct push "$CT" ./ct/ollama-bench.sh /root/ollama-bench.sh --perms 0755

declare -A V0 V1 MAXB
sample_run() { # args: label model num_gpu num_predict ; sets RES and MAXB
  local out; out=$(mktemp)
  for g in "${GPUS[@]}"; do MAXB[$g]=0; done
  X bash /root/ollama-bench.sh "$2" "$3" "$4" "$H" >"$out" 2>&1 &
  local bp=$!
  while kill -0 "$bp" 2>/dev/null; do
    for g in "${GPUS[@]}"; do b=$(gpu_busy "$g"); b=${b:-0}; (( b > MAXB[$g] )) && MAXB[$g]=$b; done
    sleep 0.5
  done
  wait "$bp"; RES=$(tail -1 "$out"); rm -f "$out"
}
tps() { awk '{ if ($2>0) printf "%.1f", $1/($2/1e9); else print "0" }' <<<"$1"; }

hdr "Benchmark: $MODEL"
X env OLLAMA_HOST="$H" "$OLL" pull "$MODEL" 2>&1 | tail -2 | indent || true
X bash /root/ollama-bench.sh --unload "$MODEL" "$H" || true
for g in "${GPUS[@]}"; do V0[$g]=$(vram_used "$g"); done

sample_run gpu "$MODEL" auto 256
if [[ $RES == ERR* || -z $RES ]]; then fail "GPU run: ${RES:-no output}"; summary; exit 1; fi
GT=$(tps "$RES"); info "GPU run: $RES  ->  ${GT} tok/s (eval)"
for g in "${GPUS[@]}"; do V1[$g]=$(vram_used "$g"); done
PS=$(X env OLLAMA_HOST="$H" "$OLL" ps 2>&1); echo "$PS" | indent
grep -q '100% GPU' <<<"$PS" && pass "ollama ps: 100% GPU" || warn "ollama ps does not show 100% GPU (partial offload or CPU)"
for g in "${GPUS[@]}"; do
  d=$(( ${V1[$g]:-0} - ${V0[$g]:-0} ))
  info "$g: VRAM +${d} MiB, peak busy ${MAXB[$g]}%"
done
USEDGPU=0; for g in "${GPUS[@]}"; do (( MAXB[$g] >= 20 && V1[$g] - V0[$g] > 256 )) && USEDGPU=1; done
(( USEDGPU )) && pass "host sysfs confirms GPU load + VRAM allocation during inference" || fail "host saw no GPU activity: inference ran on CPU"
X bash /root/ollama-bench.sh --unload "$MODEL" "$H" || true

hdr "Baseline: same model, CPU only (num_gpu=0)"
sample_run cpu "$MODEL" 0 64
if [[ $RES == ERR* || -z $RES ]]; then warn "CPU run: ${RES:-no output}"; else
  CTPS=$(tps "$RES"); info "CPU run: $RES  ->  ${CTPS} tok/s"
  R=$(awk -v g="$GT" -v c="$CTPS" 'BEGIN{ if (c>0) printf "%.2f", g/c; else print "inf" }')
  awk -v r="$R" 'BEGIN{exit !(r=="inf" || r>=1.3)}' && pass "GPU speedup ${R}x over CPU" || warn "GPU speedup only ${R}x"
fi
X bash /root/ollama-bench.sh --unload "$MODEL" "$H" || true

if [[ -n $MULTI ]]; then
  hdr "Multi-GPU split: $MULTI"
  X env OLLAMA_HOST="$H" "$OLL" pull "$MULTI" 2>&1 | tail -2 | indent || true
  for g in "${GPUS[@]}"; do V0[$g]=$(vram_used "$g"); done
  sample_run multi "$MULTI" auto 128
  if [[ $RES == ERR* || -z $RES ]]; then fail "multi run: ${RES:-no output}"; else
    info "multi run: $RES -> $(tps "$RES") tok/s"
    X env OLLAMA_HOST="$H" "$OLL" ps 2>&1 | indent
    ALL=1
    for g in "${GPUS[@]}"; do
      d=$(( $(vram_used "$g") - ${V0[$g]:-0} )); info "$g: VRAM +${d} MiB, peak busy ${MAXB[$g]}%"
      (( d > 512 )) || ALL=0
    done
    (( ALL )) && pass "model split across all ${#GPUS[@]} GPUs" || warn "model not spread across all GPUs (fits in one, or offload limited)"
  fi
  X bash /root/ollama-bench.sh --unload "$MULTI" "$H" || true
fi
summary
