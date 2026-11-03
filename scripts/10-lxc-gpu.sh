#!/usr/bin/env bash
# Pass AMD render nodes (/dev/dri/renderD*) into an LXC with the CT's own 'render' GID.
# Uses Proxmox-native devN entries (cgroup allow + node creation handled by pct). No raw lxc.* keys.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")" && source ./lib.sh

usage() { cat <<EOF2
Usage: $0 -c <ctid> [-g all|<bdf>[,<bdf>]] [-k] [-f] [-n]
  -c  container id
  -g  GPUs to pass (default all). Example: -g 0000:01:00.0
  -k  also pass /dev/dri/cardN (KMS node; not needed for compute)
  -f  replace existing /dev/dri entries in the CT
  -n  dry run
EOF2
exit 2; }
CT=; SEL=all; CARD=0; FORCE=0; DRY=0
while getopts ':c:g:kfnh' o; do
  case $o in c) CT=$OPTARG;; g) SEL=$OPTARG;; k) CARD=1;; f) FORCE=1;; n) DRY=1;; *) usage;; esac
done
[[ $CT =~ ^[0-9]+$ ]] || usage
need_root; need_pve
CONF=/etc/pve/lxc/$CT.conf; [[ -f $CONF ]] || die "no $CONF (CT on another node?)"

step "GPU selection"
mapfile -t ALL < <(amd_gpus)
if [[ $SEL == all ]]; then SELECTED=("${ALL[@]}"); else IFS=, read -r -a SELECTED <<<"$SEL"; fi
NODES=()
for g in "${SELECTED[@]}"; do
  [[ $g == 0000:* ]] || g=0000:$g
  printf '%s\n' "${ALL[@]}" | grep -qx "$g" || die "$g is not an AMD GPU on this host"
  [[ $(pci_driver "$g") == amdgpu ]] || die "$g not bound to amdgpu"
  R=$(render_node "$g"); [[ -n $R ]] || die "$g has no render node"
  NODES+=("$R"); info "$g -> $R  ($(vram_total "$g") MiB, $(pci_name "$g"))"
  if (( CARD )); then C=$(card_node "$g"); [[ -n $C ]] && NODES+=("$C") && info "$g -> $C"; fi
done

step "Container"
MAIN=$(ct_main_conf "$CT")
ST=$(pct status "$CT" | awk '{print $2}')
info "status: $ST; $(grep -E '^(hostname|ostype|unprivileged):' <<<"$MAIN" | xargs)"
[[ $(awk '/^ostype:/{print $2}' <<<"$MAIN") == alpine ]] && warn "alpine: Mesa RADV on musl works but this runbook's CT script targets Debian/Ubuntu"
EXIST=$(grep -E '^dev[0-9]+: /dev/dri/' <<<"$MAIN" || true)
LEGACY=$(grep -nE '^lxc\.(mount\.entry|cgroup2?\.devices\.allow).*(dri|kfd|226:|23[0-9]:)' <<<"$MAIN" || true)
if [[ -n $LEGACY ]]; then
  echo "$LEGACY" | indent
  die "legacy raw lxc.* DRI/KFD passthrough lines in $CONF (above, line numbers of main section). They conflict with devN entries: remove them first"
fi
if [[ -n $EXIST ]]; then
  echo "$EXIST" | indent
  (( FORCE )) || die "CT already has /dev/dri devN entries (above). Use -f to replace"
fi

GID=$(ct_group_gid "$CT" render || true)
[[ -n $GID ]] || die "no 'render' group in CT $CT. Create it: pct exec $CT -- groupadd -r render (or start CT once), then re-run"
info "CT render GID: $GID"

step "Plan"
BK=/root/lxc-conf-backup/$CT.conf.$(date +%Y%m%d-%H%M%S)
DEL=$(grep -E '^dev[0-9]+: /dev/dri/' <<<"$MAIN" | cut -d: -f1 | paste -sd, || true)
USED=$(grep -oE '^dev[0-9]+' <<<"$MAIN" | grep -vxF -f <(tr , '\n' <<<"${DEL:-__none__}") | sed 's/^dev//' || true)
ARGS=(); IDX=0
for n in "${NODES[@]}"; do
  while grep -qx "$IDX" <<<"$USED"; do IDX=$((IDX+1)); done
  ARGS+=("--dev$IDX" "$n,gid=$GID,mode=0660"); IDX=$((IDX+1))
done
[[ -n $DEL ]] && info "pct set $CT --delete $DEL"
info "pct set $CT ${ARGS[*]}"
(( DRY )) && { info "dry run: nothing written"; exit 0; }

mkdir -p "${BK%/*}"; cp -a "$CONF" "$BK"; info "backup: $BK"
[[ -n $DEL ]] && pct set "$CT" --delete "$DEL"
pct set "$CT" "${ARGS[@]}"
pass "written"
ct_main_conf "$CT" | grep -E '^dev[0-9]+:' | indent
[[ $ST == running ]] && warn "CT is running: device changes apply on restart (pct reboot $CT)"
info "next: ./20-ct-ollama.sh -c $CT   then   ./30-validate.sh -c $CT"
