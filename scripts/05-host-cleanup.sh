#!/usr/bin/env bash
# OPTIONAL. Remove leftovers of earlier amdgpu-install / ROCm / AMDVLK attempts from the PVE host.
# Default is a dry run that prints the plan. Never runs 'apt autoremove' (it would also take kernels).
# Usage: 05-host-cleanup.sh [-x]   -x = execute
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")" && source ./lib.sh
need_root; need_pve
EXEC=0; [[ ${1:-} == -x ]] && EXEC=1
run() { if (( EXEC )); then info "+ $*"; "$@"; else info "[dry-run] $*"; fi; }

step "amdgpu-dkms guard"
MODF=$(modinfo -n amdgpu 2>/dev/null)
if [[ $MODF == */updates/* || $MODF == */dkms/* ]]; then
  die "amdgpu is currently the DKMS build ($MODF). Removing ROCm/AMD repo packages may change your GPU driver. Handle amdgpu-dkms deliberately first."
fi
pass "in-tree amdgpu in use ($MODF)"

step "AMDVLK Vulkan ICD"
ICDS=$(grep -ls amdvlk /etc/vulkan/icd.d/* /usr/share/vulkan/icd.d/* 2>/dev/null || true)
OWN=$( { for f in $ICDS /opt/amdgpu/lib/x86_64-linux-gnu/amdvlk64.so; do dpkg -S "$f" 2>/dev/null; done; } | cut -d: -f1 | sort -u | xargs || true)
info "ICD files: ${ICDS:-none}; owning packages: ${OWN:-none}"
[[ -n $OWN ]] && run apt-get purge -y $OWN
for f in $ICDS; do [[ -e $f ]] && ! dpkg -S "$f" >/dev/null 2>&1 && run rm -f "$f"; done

step "ROCm / HIP userspace packages"
PKGS=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk '$1=="ii"{print $2}' \
  | grep -E '^(rocm|hip|miopen|rocblas|rocfft|rocrand|rocsolver|rocsparse|rocprim|rocthrust|rocwmma|rocalution|rccl|migraphx|composablekernel|amd-smi-lib|libhsa|hsa-|libamdhip|libamd-comgr|libhiprtc|rocprofiler|roctracer|openmp-extras|hipify|hipfort|hipcub|hiptensor|half$)' | xargs || true)
if [[ -n $PKGS ]]; then
  info "$(wc -w <<<"$PKGS") packages:"; fold -w 120 -s <<<"$PKGS" | indent
  if (( EXEC )); then
    info "simulating first:"
    apt-get -s purge $PKGS | grep -E '^(Purg|Remv) ' | awk '{print $2}' | grep -E '^(proxmox|pve|libpve|lxc|qemu)' \
      && die "purge would remove Proxmox packages (listed above); aborting"
  fi
  run apt-get purge -y $PKGS
else
  pass "none installed"
fi

step "AMD apt repositories"
for f in /etc/apt/sources.list.d/*; do
  [[ -f $f ]] || continue
  grep -qiE 'repo\.radeon\.com' "$f" && run mv "$f" "$f.disabled"
done
command -v amdgpu-install >/dev/null 2>&1 && run apt-get purge -y amdgpu-install
(( EXEC )) && apt-get update >/dev/null

step "Verify"
if command -v vulkaninfo >/dev/null 2>&1; then
  vulkaninfo --summary 2>&1 | grep -E 'WARNING|deviceName|driverName' | indent
fi
info "remaining 'no longer required' packages are left alone; review with: apt-get -s autoremove | grep -v proxmox"
(( EXEC )) || info "dry run only. Re-run with -x to apply."
