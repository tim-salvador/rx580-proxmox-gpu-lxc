#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for pve-radeon-lxc. Source this file; do not execute it.

if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_R=; C_G=; C_Y=; C_C=; C_B=; C_0=
fi

N_PASS=0; N_WARN=0; N_FAIL=0
pass()   { printf '%s[PASS]%s %s\n' "$C_G" "$C_0" "$*"; N_PASS=$((N_PASS+1)); }
warn()   { printf '%s[WARN]%s %s\n' "$C_Y" "$C_0" "$*"; N_WARN=$((N_WARN+1)); }
fail()   { printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*"; N_FAIL=$((N_FAIL+1)); }
info()   { printf '%s[INFO]%s %s\n' "$C_C" "$C_0" "$*"; }
hdr()    { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
step()   { printf '\n%s>> %s%s\n' "$C_B" "$*" "$C_0"; }
die()    { printf '%s[FATAL]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
indent() { sed 's/^/       /'; }

summary() {
  hdr "Summary"
  printf 'PASS=%d  WARN=%d  FAIL=%d\n' "$N_PASS" "$N_WARN" "$N_FAIL"
  (( N_FAIL == 0 ))
}

need_root() { [[ $EUID -eq 0 ]] || die "must run as root"; }
need_pve()  { command -v pveversion >/dev/null 2>&1 || die "not a Proxmox VE host (pveversion missing)"; }
confirm()   { [[ ${ASSUME_YES:-0} -eq 1 ]] && return 0; local a; read -r -p "$1 [y/N] " a; [[ $a =~ ^[Yy]$ ]]; }

# AMD display-class functions (VGA 0300, 3D 0302, Display 0380). Prints full BDFs.
amd_gpus()   { lspci -Dnn -d 1002: 2>/dev/null | awk '/\[03(00|02|80)\]/{print $1}'; }
pci_name()   { lspci -s "$1" 2>/dev/null | cut -d: -f3- | sed 's/^ //'; }
pci_driver() { lspci -k -s "$1" 2>/dev/null | awk -F': ' '/Kernel driver in use/{print $2}'; }
pci_ids()    { lspci -n -s "$1" 2>/dev/null | awk '{print $3}'; }

# GPU family from the marketing/codename string.
amd_family() {
  local n; n=$(pci_name "$1")
  case "$n" in
    *Ellesmere*|*Baffin*|*Lexa*|*Polaris*) echo "Polaris (GCN4, gfx803): Vulkan/RADV yes, ROCm no" ;;
    *Vega*|*Raven*|*Renoir*|*Cezanne*)     echo "Vega/GCN5 (gfx9xx): Vulkan yes, ROCm depends on exact chip" ;;
    *Navi*)                                 echo "RDNA (gfx10/11/12): Vulkan yes, ROCm depends on exact chip" ;;
    *Hawaii*|*Tonga*|*Fiji*|*Tahiti*|*Pitcairn*|*Bonaire*) echo "GCN1-3: check amdgpu.si_support/cik_support; Vulkan limited" ;;
    *)                                      echo "unknown family" ;;
  esac
}

# /dev/dri nodes for a BDF (empty if absent).
render_node() { local p=/dev/dri/by-path/pci-$1-render; [[ -e $p ]] && readlink -f "$p"; }
card_node()   { local p=/dev/dri/by-path/pci-$1-card;   [[ -e $p ]] && readlink -f "$p"; }
# Reverse: BDF for a render node path (/dev/dri/renderD128 -> 0000:01:00.0)
render_bdf()  {
  local n=${1##*/} l
  for l in /dev/dri/by-path/pci-*-render; do [[ $(readlink -f "$l") == "/dev/dri/$n" ]] && { l=${l#/dev/dri/by-path/pci-}; echo "${l%-render}"; return; }; done
}

# sysfs readers (empty on absence). Units: MiB, percent, degC, W.
sys_dev()      { echo "/sys/bus/pci/devices/$1"; }
vram_total()   { local f; f=$(sys_dev "$1")/mem_info_vram_total; [[ -r $f ]] && echo $(( $(cat "$f") / 1048576 )); }
vram_used()    { local f; f=$(sys_dev "$1")/mem_info_vram_used;  [[ -r $f ]] && echo $(( $(cat "$f") / 1048576 )); }
# gpu_busy_percent returns EBUSY intermittently while the SMU is servicing a busy GPU: retry, then give up quietly
gpu_busy()     { local f v _; f=$(sys_dev "$1")/gpu_busy_percent; [[ -r $f ]] || return 0
                 for _ in 1 2 3; do v=$(cat "$f" 2>/dev/null) && { echo "$v"; return 0; }; sleep 0.05; done; }
gpu_temp()     { local f; f=$(ls "$(sys_dev "$1")"/hwmon/hwmon*/temp1_input 2>/dev/null | head -1); [[ -n $f ]] && echo $(( $(cat "$f") / 1000 )); }
gpu_power()    { local f; f=$(ls "$(sys_dev "$1")"/hwmon/hwmon*/power1_average "$(sys_dev "$1")"/hwmon/hwmon*/power1_input 2>/dev/null | head -1); [[ -n $f ]] && echo $(( $(cat "$f") / 1000000 )); }

# Main (non-snapshot) section of a CT config.
ct_main_conf() { awk '/^\[/{exit} {print}' "/etc/pve/lxc/$1.conf"; }

# Read a group's GID from a CT's /etc/group without starting it (works stopped or running).
ct_group_gid() {
  local ct=$1 grp=$2 st gid
  st=$(pct status "$ct" | awk '{print $2}')
  if [[ $st == running ]]; then
    gid=$(pct exec "$ct" -- getent group "$grp" | cut -d: -f3)
  else
    pct mount "$ct" >/dev/null || return 1
    gid=$(awk -F: -v g="$grp" '$1==g{print $3}' "/var/lib/lxc/$ct/rootfs/etc/group")
    pct unmount "$ct" >/dev/null
  fi
  echo "$gid"
}
