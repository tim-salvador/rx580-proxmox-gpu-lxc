#!/usr/bin/env bash
# Read-only host audit for AMD Radeon -> LXC (Vulkan/RADV). Changes nothing.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")" && source ./lib.sh
need_root; need_pve
KV=$(uname -r)

hdr "Platform"
pveversion -v | grep -E '^(proxmox-ve|pve-manager|lxc-pve|running kernel):' | indent
info "kernel $KV, $(. /etc/os-release; echo "$PRETTY_NAME")"
[[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] && pass "cgroup v2" || warn "cgroup fs: $(stat -fc %T /sys/fs/cgroup)"

hdr "GPUs"
mapfile -t GPUS < <(amd_gpus)
(( ${#GPUS[@]} )) || { fail "no AMD VGA/3D controller on the PCI bus"; summary; exit 1; }
for g in "${GPUS[@]}"; do
  info "$g [$(pci_ids "$g")] $(pci_name "$g")"
  info "  subsystem: $(lspci -vnn -s "$g" | awk -F': ' '/Subsystem/{print $2; exit}')"
  info "  family: $(amd_family "$g")"
  DRV=$(pci_driver "$g")
  case "$DRV" in
    amdgpu)   pass "  driver: amdgpu" ;;
    vfio-pci) fail "  driver: vfio-pci (reserved for VM passthrough; LXC cannot use it)" ;;
    radeon)   fail "  driver: radeon (legacy; no Vulkan). Polaris must run on amdgpu" ;;
    "")       fail "  no driver bound" ;;
    *)        warn "  driver: $DRV" ;;
  esac
  R=$(render_node "$g"); C=$(card_node "$g")
  [[ -n $R ]] && pass "  render node: $R ($(stat -c '%A %U:%G' "$R"))" || fail "  no render node for $g"
  [[ -n $C ]] && info "  card node:   $C"
  VT=$(vram_total "$g"); VU=$(vram_used "$g")
  [[ -n $VT ]] && info "  VRAM: ${VU:-?} / ${VT} MiB used, busy=$(gpu_busy "$g")%, temp=$(gpu_temp "$g")C, power=$(gpu_power "$g")W"
  lspci -vv -s "$g" 2>/dev/null | grep -E 'LnkSta:' | head -1 | sed 's/^\s*/  link: /' | indent
done

hdr "Kernel driver origin"
MODF=$(modinfo -n amdgpu 2>/dev/null)
info "amdgpu module: $MODF"
if [[ $MODF == */updates/* || $MODF == */dkms/* ]]; then
  warn "amdgpu comes from amdgpu-dkms (AMD repo), not the PVE kernel: it must rebuild on every kernel upgrade"
else
  pass "in-tree amdgpu (no DKMS dependency on kernel upgrades)"
fi
dkms status 2>/dev/null | grep -i amdgpu | indent
grep -rhsE '^\s*blacklist\s+amdgpu' /etc/modprobe.d /usr/lib/modprobe.d && fail "amdgpu is blacklisted"
grep -rhsE 'vfio-pci.*ids=' /etc/modprobe.d | grep -v '^\s*#' | indent
for g in "${GPUS[@]}"; do
  grep -rhsE '^[^#]*vfio-pci.*ids=' /etc/modprobe.d | grep -qi "$(pci_ids "$g")" && fail "$(pci_ids "$g") is in an active vfio-pci ids= line"
done
info "cmdline: $(cat /proc/cmdline)"

hdr "VM conflicts"
for g in "${GPUS[@]}"; do
  S=${g#0000:}; S=${S%.*}
  HITS=$(grep -lE "^hostpci[0-9]+:.*(${S}|${g%.*})" /etc/pve/qemu-server/*.conf 2>/dev/null | xargs -r -n1 basename | xargs || true)
  [[ -n $HITS ]] && fail "$g referenced by VM hostpci: $HITS" || pass "$g not referenced by raw VM hostpci"
done
if [[ -f /etc/pve/mapping/pci.cfg ]]; then
  # mapping names whose entries include one of our GPUs
  MAPS=$(awk -v g="$(printf '%s|' "${GPUS[@]}")" 'BEGIN{sub(/\|$/,"",g)} /^[^ \t]/{n=$1} $0 ~ g {print n}' /etc/pve/mapping/pci.cfg | sort -u)
  for m in $MAPS; do
    U=$(grep -lE "^hostpci[0-9]+:.*mapping=$m(,|$)" /etc/pve/qemu-server/*.conf 2>/dev/null | xargs -r -n1 basename | xargs || true)
    [[ -n $U ]] && fail "PCI mapping '$m' (contains these GPUs) used by: $U. Starting that VM steals the GPUs from amdgpu/LXC" \
      || info "PCI mapping '$m' contains these GPUs but no VM uses it (keep it that way)"
  done
fi

hdr "Firmware / runtime health (this boot)"
ERR=$(journalctl -k -b --no-pager 2>/dev/null | grep -iE 'amdgpu' | grep -iE 'error|fail|timeout|reset|hang|fault' | grep -viE 'failed to (load|find) .*(optional|vbios)|Disabling VM faults because of PRT request' || true)
if [[ -z $ERR ]]; then pass "no amdgpu error/timeout/reset messages"; else warn "amdgpu messages to review:"; echo "$ERR" | tail -15 | indent; fi
journalctl -k -b --no-pager 2>/dev/null | grep -iE 'amdgpu.*(fw|firmware) version|amdgpu: .*VRAM' | head -6 | indent
dpkg-query -W -f='${Package} ${Version}\n' firmware-amd-graphics 2>/dev/null | indent

hdr "Host /dev/dri"
ls -l /dev/dri /dev/dri/by-path | indent
[[ -e /dev/kfd ]] && info "/dev/kfd present (ROCm compute node; not used by the Vulkan path)"
for r in /dev/dri/renderD*; do
  [[ $(stat -c %a "$r") == 666 ]] && warn "$r is world-writable on the host (default is 0660 root:render). Not required for LXC; origin:" && grep -rlsE 'renderD|dri|KERNEL=="card' /etc/udev/rules.d | indent
done

hdr "Host Vulkan (diagnostic only; containers carry their own userspace)"
if command -v vulkaninfo >/dev/null 2>&1; then
  VK=$(vulkaninfo --summary 2>&1)
  grep -E 'deviceName|driverName' <<<"$VK" | indent
  N=$(grep -c 'deviceName.*RADV' <<<"$VK" || true)
  (( N == ${#GPUS[@]} )) && pass "RADV enumerates all ${#GPUS[@]} GPUs" || warn "RADV devices=$N, PCI GPUs=${#GPUS[@]}"
  grep -q 'amdvlk' <<<"$VK" && warn "broken AMDVLK ICD present (see 05-host-cleanup.sh)"
else
  info "vulkaninfo not installed on host (optional: apt install vulkan-tools mesa-vulkan-drivers)"
fi
ls /etc/vulkan/icd.d /usr/share/vulkan/icd.d 2>/dev/null | indent

hdr "Leftovers from earlier ROCm / amdgpu-install attempts"
command -v amdgpu-install >/dev/null 2>&1 && warn "amdgpu-install present: $(command -v amdgpu-install)"
for f in /etc/apt/sources.list.d/*; do [[ -f $f ]] && grep -qiE 'repo\.radeon\.com' "$f" && echo "apt source: $f"; done | indent
NR=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk '$1=="ii"{print $2}' | grep -cE '^(rocm|hip|miopen|rocblas|rocfft|rocrand|rocsolver|rocsparse|rccl|migraphx|amdvlk|amd-smi|libhsa|hsa-|libamdhip|libamd-comgr|rocprofiler|roctracer)' || true)
(( NR )) && warn "$NR ROCm/AMDVLK packages installed (useless for Polaris on the host; see 05-host-cleanup.sh)" || pass "no ROCm/AMDVLK packages"

hdr "Pending kernel upgrades"
apt list --upgradable 2>/dev/null | grep -E '^proxmox-(kernel|headers|default)' | indent || true
apt-mark showhold | grep -E 'proxmox-(kernel|headers)' && info "held kernel packages above (unhold: apt-mark unhold <pkg>)"
info "in-tree amdgpu has no DKMS step: kernel upgrades are low-risk for this GPU path"

summary
