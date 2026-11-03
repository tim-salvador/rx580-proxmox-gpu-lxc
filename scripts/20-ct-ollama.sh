#!/usr/bin/env bash
# Install Mesa RADV + pinned Ollama (Vulkan backend) inside a CT, driven from the host.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")" && source ./lib.sh
usage() { cat <<EOF2
Usage: $0 -c <ctid> [-v <version|latest>] [-l <listen addr>] [-P]
  -v  Ollama release (default latest; e.g. 0.40.13). Pin it for reproducibility.
  -l  OLLAMA_HOST, e.g. 0.0.0.0:11434 for LAN clients (unauthenticated API). Default: Ollama's 127.0.0.1:11434
  -P  skip setcap cap_perfmon
EOF2
exit 2; }
CT=; VER=latest; LISTEN=; NOCAP=
while getopts ':c:v:l:Ph' o; do case $o in c) CT=$OPTARG;; v) VER=$OPTARG;; l) LISTEN=$OPTARG;; P) NOCAP=nocap;; *) usage;; esac; done
[[ $CT =~ ^[0-9]+$ ]] || usage
need_root; need_pve
grep -qE '^dev[0-9]+: /dev/dri/renderD' <(ct_main_conf "$CT") || die "CT $CT has no render node: run 10-lxc-gpu.sh first"
[[ $(pct status "$CT" | awk '{print $2}') == running ]] || { info "starting CT $CT"; pct start "$CT"; sleep 5; }
pct exec "$CT" -- sh -c 'ls /dev/dri/renderD*' >/dev/null 2>&1 || die "render node not visible in CT: pct reboot $CT"
pct exec "$CT" -- sh -c 'getent hosts github.com >/dev/null' || die "CT $CT has no DNS/network"
pct push "$CT" ./ct/install-ollama-vulkan.sh /root/install-ollama-vulkan.sh --perms 0755
pct exec "$CT" -- bash /root/install-ollama-vulkan.sh "$VER" "$LISTEN" "$NOCAP"
info "next: ./30-validate.sh -c $CT"
