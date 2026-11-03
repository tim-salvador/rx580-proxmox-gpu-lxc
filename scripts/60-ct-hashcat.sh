#!/usr/bin/env bash
# Set up GPU hashcat (Mesa Rusticl) in a Kali/Debian CT that already has render nodes passed in
# via 10-lxc-gpu.sh. Installs the Rusticl ICD, makes RUSTICL_ENABLE persistent, installs the
# wrapper, and verifies both GPUs enumerate for hashcat. Driven from the PVE host.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")" && source ./lib.sh
usage() { echo "Usage: $0 -c <ctid> [-b]   -b also runs an MD5 benchmark"; exit 2; }
CT=; BENCH=0
while getopts ':c:bh' o; do case $o in c) CT=$OPTARG;; b) BENCH=1;; *) usage;; esac; done
[[ $CT =~ ^[0-9]+$ ]] || usage
need_root; need_pve
grep -qE '^dev[0-9]+: /dev/dri/renderD' <(ct_main_conf "$CT") || die "CT $CT has no render node: run 10-lxc-gpu.sh first"
[[ $(pct status "$CT" | awk '{print $2}') == running ]] || { info "starting CT $CT"; pct start "$CT"; sleep 5; }
pct exec "$CT" -- sh -c 'ls /dev/dri/renderD*' >/dev/null 2>&1 || die "render node not visible in CT: pct reboot $CT"
pct push "$CT" ./ct/hashcat-gpu.sh /usr/local/bin/hashcat-gpu --perms 0755
pct exec "$CT" -- env BENCH="$BENCH" bash -s <<'IN'
set -eu
export DEBIAN_FRONTEND=noninteractive RUSTICL_ENABLE=radeonsi
command -v hashcat >/dev/null || { apt-get update && apt-get install -y hashcat; }
# Rusticl ICD + clinfo. mesa-opencl-icd provides Rusticl on Debian/Kali.
dpkg -s mesa-opencl-icd >/dev/null 2>&1 || { apt-get update && apt-get install -y mesa-opencl-icd clinfo; }
# Persist the opt-in for login shells and systemd; /etc/environment is read by both.
grep -q '^RUSTICL_ENABLE=' /etc/environment || echo 'RUSTICL_ENABLE=radeonsi' >> /etc/environment
echo "== render nodes =="; ls -ln /dev/dri
echo "== Rusticl devices =="; clinfo -l 2>&1 | grep -iE 'rusticl|RX 580|polaris' || true
echo "== hashcat GPU enumeration =="
N=$(hashcat -d 1,2 --backend-ignore-cuda --backend-ignore-hip -I 2>&1 | grep -c 'Type...........: GPU' || true)
echo "hashcat GPU devices: $N"
[ "$N" -ge 2 ] || { echo "FAIL: expected 2 GPU devices"; exit 1; }
if [ "$BENCH" = 1 ]; then
  echo "== MD5 benchmark (both cards) =="
  hashcat-gpu -b -m 0 -w 3 2>&1 | grep -E 'Speed.#'
fi
echo "PASS: GPU hashcat ready. Run with: hashcat-gpu -m <mode> <hash> <wordlist> -w 3"
IN
info "wrapper installed as /usr/local/bin/hashcat-gpu in CT $CT"
info "card split: export HASHCAT_GPU_DEVICES=2 in a run to leave renderD128 (card 0) for Ollama"
