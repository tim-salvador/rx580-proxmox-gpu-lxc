#!/usr/bin/env bash
# Runs INSIDE the CT (Debian 12/13, Ubuntu 22.04/24.04). Installs Mesa RADV + a pinned Ollama
# release with the Vulkan backend. Skips the CUDA (~2.3 GB) and ROCm bundles: ROCm does not
# support Polaris (gfx803). Existing models in ~ollama/.ollama are preserved.
# Usage: install-ollama-vulkan.sh <version|latest> [listen_addr] [nocap]
set -euo pipefail
VER=${1:-latest}; LISTEN=${2:-}; NOCAP=${3:-}
die()  { echo "[FATAL] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
[[ $EUID -eq 0 ]] || die "run as root inside the CT"

info "OS: $(. /etc/os-release; echo "$PRETTY_NAME")"
ls /dev/dri/renderD* >/dev/null 2>&1 || die "no /dev/dri/renderD* in CT: run 10-lxc-gpu.sh on the host and restart the CT"
ls -l /dev/dri | sed 's/^/       /'

# Leftovers from amdgpu-install/ROCm attempts break apt (SHA1-signed repo keys are rejected since
# 2026-02-01) and can shadow Debian's libdrm/Mesa via /opt/amdgpu or /opt/rocm in the loader path.
RADEON_SRC=$(grep -rlsE 'repo\.radeon\.com' /etc/apt/sources.list /etc/apt/sources.list.d/ | grep -vE '\.disabled$' || true)
[[ -z $RADEON_SRC ]] || die "active repo.radeon.com apt sources: $RADEON_SRC (disable them first; see README section 6a)"
SHADOW=$(grep -rlsE '/opt/(amdgpu|rocm)' /etc/ld.so.conf /etc/ld.so.conf.d/ || true)
[[ -z $SHADOW ]] || die "loader path includes /opt/amdgpu or /opt/rocm via: $SHADOW (would shadow Debian libdrm/Mesa; see README section 6a)"

export DEBIAN_FRONTEND=noninteractive
apt-get update
# no pciutils/lshw on purpose: nothing here needs PCI enumeration
apt-get install -y --no-install-recommends ca-certificates curl zstd jq libcap2-bin mesa-vulkan-drivers vulkan-tools

info "Vulkan in CT (as root):"
vulkaninfo --summary 2>&1 | grep -E 'WARNING|deviceName|driverName|apiVersion' | sed 's/^/       /'
vulkaninfo --summary 2>/dev/null | grep -q RADV || die "RADV sees no GPU in the CT (check device nodes / group)"

if [[ $VER == latest ]]; then
  VER=$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/ollama/ollama/releases/latest | sed 's#.*/tag/v##')
  [[ $VER =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "could not resolve latest Ollama release"
fi
VER=${VER#v}
BASE=https://github.com/ollama/ollama/releases/download/v$VER
TARBALL=ollama-linux-amd64.tar.zst
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
info "Ollama v$VER"
curl -fsSL "$BASE/sha256sum.txt" -o "$TMP/sha256sum.txt" || die "no sha256sum.txt for v$VER"
SUM=$(awk -v f="./$TARBALL" '$2==f{print $1}' "$TMP/sha256sum.txt")
[[ -n $SUM ]] || die "$TARBALL not listed in sha256sum.txt for v$VER"
curl -fL --retry 3 -o "$TMP/$TARBALL" "$BASE/$TARBALL"
echo "$SUM  $TMP/$TARBALL" | sha256sum -c - || die "checksum mismatch"

systemctl stop ollama 2>/dev/null || true
rm -rf /usr/local/lib/ollama
install -d -m755 /usr/local/bin /usr/local/lib/ollama
zstd -dc "$TMP/$TARBALL" | tar -xf - -C /usr/local --exclude='lib/ollama/cuda_v*'
[[ -f /usr/local/lib/ollama/vulkan/libggml-vulkan.so ]] || die "Vulkan backend missing from v$VER tarball"
/usr/local/bin/ollama --version 2>/dev/null | sed 's/^/       /' || true

id ollama >/dev/null 2>&1 || useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama
for g in render video; do if getent group "$g" >/dev/null; then usermod -aG "$g" ollama; fi; done
info "ollama groups: $(id -nG ollama)"

if [[ ! -f /etc/systemd/system/ollama.service ]]; then
cat >/etc/systemd/system/ollama.service <<'UNIT'
[Unit]
Description=Ollama Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
UNIT
fi
install -d /etc/systemd/system/ollama.service.d
{
  echo "# managed by pve-radeon-lxc"
  echo "[Service]"
  SG=$(for g in render video; do if getent group "$g" >/dev/null; then printf '%s ' "$g"; fi; done)
  if [[ -n $SG ]]; then echo "SupplementaryGroups=${SG% }"; fi
  echo 'Environment="OLLAMA_VULKAN=1"'
  if [[ -n $LISTEN ]]; then echo "Environment=\"OLLAMA_HOST=$LISTEN\""; fi
} >/etc/systemd/system/ollama.service.d/10-radeon-vulkan.conf
cat /etc/systemd/system/ollama.service.d/*.conf | sed 's/^/       /'

if [[ $NOCAP != nocap ]]; then
  # Lets Ollama read free VRAM via Vulkan (otherwise it estimates). Verified in 30-validate.sh.
  setcap cap_perfmon+ep /usr/local/bin/ollama && getcap /usr/local/bin/ollama | sed 's/^/       /' \
    || info "setcap failed (filesystem without xattr support?); Ollama will estimate VRAM"
fi

info "Vulkan as the 'ollama' user (proves group permissions):"
runuser -u ollama -- vulkaninfo --summary 2>&1 | grep -E 'deviceName' | sed 's/^/       /'
runuser -u ollama -- vulkaninfo --summary 2>/dev/null | grep -q RADV || die "ollama user cannot use the GPU (render group / node mode)"

systemctl daemon-reload
systemctl enable --now ollama
sleep 5
systemctl is-active --quiet ollama || { journalctl -u ollama -b --no-pager | tail -40; die "ollama failed to start"; }
journalctl -u ollama -b --no-pager | grep -iE 'inference compute|vulkan|no compatible' | tail -6 | sed 's/^/       /'
echo "PASS: Ollama v$VER installed with Vulkan backend"
