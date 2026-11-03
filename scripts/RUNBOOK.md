# RUNBOOK: AMD Radeon (Polaris) -> LXC on Proxmox VE 9.x (Vulkan + Rusticl)

> Operational reference for the scripts in this directory. For the narrative writeup, see [../docs/writeup.md](../docs/writeup.md).

Status as of 2026-11-03. Built and validated on host `pve` (note: host storage is a spinning HDD, no SSD; see Operations for the load-time implication): PVE 9.2.3, kernel 7.0.6-2-pve, lxc-pve 7.0.0-2,
2x PowerColor RX 580 8 GB (Ellesmere, gfx803) at `0000:01:00.0` (renderD128) and `0000:02:00.0` (renderD129), both on in-tree `amdgpu`.
Two consumers share the same render nodes: Ollama (Vulkan) in CT 120, and hashcat (Rusticl OpenCL) in Kali CT 126.
Every phase is **check -> act -> verify**. Scripts stop on the first failed precondition.

## 1. Why this design

| Decision | Reason |
|---|---|
| **Vulkan (Mesa RADV), not ROCm** | ROCm dropped Polaris/gfx803. RADV already enumerates both cards on this host. Ollama ships a Vulkan backend (`lib/ollama/vulkan/libggml-vulkan.so`) in the main Linux tarball and enables it by default. |
| **Render nodes only** (`/dev/dri/renderD*`) | Compute needs the render node, not KMS (`cardN`) or `/dev/kfd` (ROCm). Least privilege. `-k` adds `cardN` if you ever need it. |
| **Proxmox `devN:` entries with the CT's `render` GID, mode 0660** | pct handles cgroup allow + node creation. No raw `lxc.*` keys, no host-side chmod 666, survives renumbering checks. |
| **Ollama from the GitHub release, pinned, checksum-verified, CUDA libs excluded** | `install.sh` would pull the ROCm bundle when it sees an AMD GPU (useless on gfx803) plus ~2.3 GB of CUDA libs. Manual install is reproducible. |
| **Nothing installed on the host** | `amdgpu` is in-tree: no DKMS, no driver/kernel coupling. Kernel upgrades are low-risk for this path. |
| **Render nodes are shareable** | Unlike VM passthrough, several CTs can use the same GPU concurrently. VRAM is the contended resource. |

Realistic expectations on RX 580 8 GB via Vulkan: community reports in the 15 to 25 tok/s range for 3B to 8B Q4 models per card. Models above ~7 GiB can split across both cards (16 GiB total) at lower speed.

## 2. Bundle and run order

```
00-preflight.sh          read-only host audit
05-host-cleanup.sh       OPTIONAL: remove AMDVLK/ROCm/amdgpu-install leftovers (dry run by default)
10-lxc-gpu.sh            pass render nodes into a CT with the CT's render GID
20-ct-ollama.sh          install Mesa RADV + pinned Ollama (Vulkan) inside the CT
30-validate.sh           wiring + Vulkan as root and as 'ollama' + Ollama discovery + GPU vs CPU benchmark
60-ct-hashcat.sh         install Rusticl + GPU hashcat in a Kali/Debian CT (same render-node passthrough)
ct/install-ollama-vulkan.sh   pushed into the CT by 20-ct-ollama.sh
ct/ollama-bench.sh            pushed into the CT by 30-validate.sh
ct/hashcat-gpu.sh             wrapper installed as /usr/local/bin/hashcat-gpu by 60-ct-hashcat.sh
```

```bash
# from the repo's scripts/ directory, on the Proxmox host (as root):
chmod +x *.sh ct/*
./00-preflight.sh | tee /root/radeon-preflight-$(date +%F).log
./05-host-cleanup.sh                     # read the plan; then ./05-host-cleanup.sh -x if you agree
pct shutdown <CTID>
./10-lxc-gpu.sh -c <CTID> -n             # dry run
./10-lxc-gpu.sh -c <CTID>                # both GPUs; or -g 0000:01:00.0 for one
./20-ct-ollama.sh -c <CTID> -v 0.40.13 -l 0.0.0.0:11434
./30-validate.sh -c <CTID> -M <12-14B Q4 model>     # -M optional: proves split across both cards
```

## 3. Phase A: host audit (read-only)

`./00-preflight.sh` checks, with manual equivalents:

```bash
pveversion -v | grep -E 'proxmox-ve|pve-manager|lxc-pve|running kernel'
lspci -Dnnk -d 1002:                                  # both GPUs, driver in use: amdgpu
lspci -vnn -s 01:00.0 | grep Subsystem                # PowerColor RX 580 [148c:2378]
modinfo -n amdgpu                                     # in-tree path, not /updates/dkms
grep -rE 'amdgpu|radeon|vfio' /etc/modprobe.d/
ls -l /dev/dri /dev/dri/by-path                       # BDF -> renderD mapping
for g in 0000:01:00.0 0000:02:00.0; do d=/sys/bus/pci/devices/$g
  echo "$g vram=$(( $(cat $d/mem_info_vram_total)/1048576 ))MiB used=$(( $(cat $d/mem_info_vram_used)/1048576 ))MiB busy=$(cat $d/gpu_busy_percent)%"; done
lspci -vv -s 01:00.0 | grep LnkSta                    # expect x8 per card on Z97 dual x16
grep -E '^hostpci' /etc/pve/qemu-server/*.conf; cat /etc/pve/mapping/pci.cfg
journalctl -k -b | grep -i amdgpu | grep -iE 'error|fail|timeout|reset'
vulkaninfo --summary | grep -E 'deviceName|driverName'
```

Gate: no FAIL. Watch items specific to this host:
- PCI mapping `RadeonRX570X` contains both cards. Unused today. If a VM ever gets `hostpci: mapping=RadeonRX570X` and starts, vfio-pci takes both GPUs away from amdgpu and every CT using them breaks.
- `/dev/dri/renderD*` is 0666 on the host (default is 0660 root:render). Not needed by this design; preflight shows which udev rule set it.

## 4. Phase B (optional): host cleanup

Leftovers from earlier attempts: AMDVLK ICD (`/opt/amdgpu/.../amdvlk64.so`, fails `vkCreateInstance`), ROCm/HIP packages, possibly AMD apt repos. None are needed on the host (containers carry their own Vulkan userspace).

```bash
./05-host-cleanup.sh        # prints the plan
./05-host-cleanup.sh -x     # purges AMDVLK owner pkg, ROCm/HIP pkgs, disables repo.radeon.com sources
```

Guards: aborts if `amdgpu` is the DKMS build; simulates the purge and aborts if any `proxmox*/pve*/lxc*/qemu*` package would go; never runs `apt autoremove` (that list also contains your 6.8.12 fallback kernels). Verify: `vulkaninfo --summary` shows no loader WARNING.

## 5. Phase C: pass the GPUs into the CT

CT requirements: Debian 12/13 or Ubuntu 22.04/24.04, network access to github.com. The script reads the CT's `render` GID from its `/etc/group` (via `pct mount` when stopped) so the node inside the CT is owned by the right group.

```bash
pct shutdown <CTID>
./10-lxc-gpu.sh -c <CTID> -n
./10-lxc-gpu.sh -c <CTID>
```

Result in `/etc/pve/lxc/<CTID>.conf` (GID varies per template):

```
dev0: /dev/dri/renderD128,gid=993,mode=0660
dev1: /dev/dri/renderD129,gid=993,mode=0660
```

Manual equivalent:

```bash
pct exec <CTID> -- getent group render          # or read /etc/group via pct mount
pct set <CTID> --dev0 /dev/dri/renderD128,gid=<GID>,mode=0660 --dev1 /dev/dri/renderD129,gid=<GID>,mode=0660
pct start <CTID> && pct exec <CTID> -- ls -ln /dev/dri
```

Existing raw `lxc.mount.entry`/`lxc.cgroup2.devices.allow` DRI lines are reported as conflicts; remove them.

## 6a. CT leftovers from earlier ROCm attempts (check before Phase D)

A CT that once ran `amdgpu-install` carries Ubuntu (jammy) ROCm packages, `repo.radeon.com` sources whose SHA1-bound key apt now rejects, and possibly `/etc/ld.so.conf.d` entries for `/opt/amdgpu` or `/opt/rocm` that can shadow Debian's `libdrm_amdgpu`/Mesa. `ct/install-ollama-vulkan.sh` refuses to run until these are gone. ROCm cannot drive gfx803, so for a dedicated Vulkan CT remove it all: disable the sources, list packages that no enabled repo provides (`apt list --installed | grep ',local]'`), simulate the purge, purge, remove the loader entries, `ldconfig`.

## 6. Phase D: Mesa RADV + Ollama inside the CT

```bash
./20-ct-ollama.sh -c <CTID> -v 0.40.13 -l 0.0.0.0:11434
```

Inside the CT this:
1. installs `mesa-vulkan-drivers vulkan-tools zstd jq curl libcap2-bin` (no `pciutils` on purpose)
2. proves RADV sees the GPUs as root
3. downloads `ollama-linux-amd64.tar.zst` for the pinned tag from GitHub, verifies it against the release `sha256sum.txt`, extracts to `/usr/local` excluding `lib/ollama/cuda_v*`
4. creates/keeps the `ollama` user, adds it to `render`/`video`, keeps an existing `ollama.service` (models in `/usr/share/ollama/.ollama` are untouched)
5. writes drop-in `/etc/systemd/system/ollama.service.d/10-radeon-vulkan.conf` (SupplementaryGroups, `OLLAMA_VULKAN=1`, optional `OLLAMA_HOST`)
6. `setcap cap_perfmon+ep /usr/local/bin/ollama` (Ollama docs: lets Vulkan report free VRAM; skip with `-P`)
7. proves RADV works **as the `ollama` user**, starts the service, prints the `inference compute` log lines

`-l 0.0.0.0:11434` exposes an unauthenticated API to the LAN. Put it behind your reverse proxy/firewall as you do for `ollama.megagibby.com`.

Manual spot checks:

```bash
pct exec <CTID> -- vulkaninfo --summary | grep -E 'deviceName|driverName'
pct exec <CTID> -- runuser -u ollama -- vulkaninfo --summary | grep deviceName
pct exec <CTID> -- journalctl -u ollama -b | grep -i 'inference compute'
pct exec <CTID> -- systemctl cat ollama
```

## 7. Phase E: validate

```bash
./30-validate.sh -c <CTID> -s                       # default model llama3.2:3b
./30-validate.sh -c <CTID> -M <model larger than 8 GiB>   # also proves dual-GPU split
```

What counts as proof (not just "it started"):

| Check | Evidence |
|---|---|
| Wiring | each `devN` render node maps to a live BDF; node GID in CT == CT `render` GID |
| Permissions | `vulkaninfo` lists N x RADV both as root **and** as `ollama` |
| Discovery | Ollama log has N `inference compute ... Vulkan` lines; warns if llvmpipe was picked up |
| GPU execution | `ollama ps` shows `100% GPU` **and** host sysfs shows peak `gpu_busy_percent` >= 20% plus VRAM growth on the card during the run |
| Benefit | same prompt with `num_gpu=0` (CPU only); GPU must be >= 1.3x faster |
| Multi-GPU (`-M`) | VRAM grows > 512 MiB on every passed card |
| Health | no amdgpu ring timeouts/resets/page faults this boot |

Reboot test once: `reboot`, then `./30-validate.sh -c <CTID> -B` with the CT on `onboot: 1`.

## 8. Operations

- **Kernel upgrades**: in-tree amdgpu, no DKMS. If you held kernels during the NVIDIA work: `apt-mark unhold proxmox-kernel-7.0 proxmox-headers-7.0`. After upgrading and rebooting: `./00-preflight.sh && ./30-validate.sh -c <CTID> -B`. Render node numbers can shift if devices are added; validate catches that.
- **Ollama upgrades**: `./20-ct-ollama.sh -c <CTID> -v <new>` (re-applies setcap; a plain binary replace drops file caps).
- **Model load time is disk-bound, and this host has no SSD.** Measured on `pve`: the host disk backing local-lvm (`pve/data` on a Seagate ST2000LX001) reads at ~30 MB/s, and NFS at ~50 MB/s. Both are slow. A 4.9 GB (8B Q4) model takes ~90-150 s to load from either; generation is unaffected (~29 tok/s on one RX 580). This is **not** fixable in software on spinning storage:
  - **Primary mitigation: keep models resident.** Drop-in `/etc/systemd/system/ollama.service.d/20-keepalive.conf` with `Environment="OLLAMA_KEEP_ALIVE=-1"` (never unload) for a model you use constantly, or `1h` if you want card 0 to free for hashcat when idle. With `-1` you pay the load once per boot and never again; behind Open WebUI the model stays hot. Tradeoff: `-1` pins ~2.5 GB on card 0, so run hashcat with `HASHCAT_GPU_DEVICES=2` (card 1 only) while Ollama is pinned.
  - **The only structural fix is a real SSD in the host.** A cheap SATA/NVMe SSD holding `/var/lib/vz` or a dedicated model-cache dataset cuts cold load from ~2 min to a few seconds. Nothing else (NFS tuning, more CT RAM, local-lvm on the same HDD) changes it, because the bottleneck is the rotational disk, not the filesystem or network.
  - Model storage on `pve` lives on a local-lvm thin volume mounted at the model dir (`pct set <CTID> --mp0 local-lvm:<size>,mp=/usr/share/ollama/.ollama/models,backup=0`). On this host that is the same HDD as NFS speed-wise; it is kept local only to isolate model I/O from the NFS-backed rootfs, not for load speed. On a host with an SSD, point this mount at the SSD and cold load drops to seconds.
- **Pin one GPU per CT**: `./10-lxc-gpu.sh -c <A> -g 0000:01:00.0 -f` and `./10-lxc-gpu.sh -c <B> -g 0000:02:00.0 -f`. Inside a CT, Vulkan indices follow the passed nodes; `GGML_VK_VISIBLE_DEVICES=<idx>` narrows further.
- **Live monitoring on the host**: `watch -n1 'for g in 0000:01:00.0 0000:02:00.0; do d=/sys/bus/pci/devices/$g; echo "$g busy=$(cat $d/gpu_busy_percent)% vram=$(( $(cat $d/mem_info_vram_used)/1048576 ))MiB"; done'`

## 8b. GPU hashcat in a Kali CT (Rusticl / OpenCL)

The same render-node passthrough (`10-lxc-gpu.sh`) feeds a Kali/Debian CT; hashcat reaches the GPUs through Mesa **Rusticl** (OpenCL), not Vulkan (hashcat v7's Vulkan backend did not enumerate these Polaris cards) and not ROCm (gfx803 unsupported).

```bash
pct shutdown 126
# strip any legacy raw lxc.* DRI/kfd lines first (same as the Ollama CT), then:
./10-lxc-gpu.sh -c 126
./60-ct-hashcat.sh -c 126 -b
```

`60-ct-hashcat.sh` installs `mesa-opencl-icd` + `clinfo` + `hashcat`, persists `RUSTICL_ENABLE=radeonsi` in `/etc/environment` (mandatory: Rusticl is opt-in per driver, no GPU enumerates without it), installs the `hashcat-gpu` wrapper, and checks both GPUs enumerate.

Run cracking through the wrapper (forces `RUSTICL_ENABLE`, `-d 1,2`, and ignores CUDA/HIP):

```bash
hashcat-gpu -m 22000 capture.hc22000 wordlist.txt -w 3     # both cards
HASHCAT_GPU_DEVICES=2 hashcat-gpu -m 0 hashes.txt wl.txt    # card 1 only (leave card 0 for Ollama)
```

Gotchas specific to this stack:
- `-d` selects devices by number; `-D` selects backend *type* and also matches the PoCL CPU device, so `-D 1` benchmarks the CPU and skips the GPUs. The wrapper uses `-d`.
- Rusticl on Polaris caps a single allocation at ~2047 MB (full 8 GB usable across buffers). Large wordlists/masks can exceed that per kernel; on `CL_OUT_OF_RESOURCES`, add `-n 128` (or lower) to a real run. `-n` is rejected under `-b`.
- Measured on 2x RX 580 (`-w 3`, combined): MD5 8123 MH/s, SHA1 3801 MH/s, NTLM 3301 MH/s, SHA2-256 1814 MH/s, WPA2 293.3 kH/s, bcrypt 19043 H/s. Fast unsalted and WPA2 are ~30 to 90x the i7-4790K; bcrypt gains ~17x but stays slow in absolute terms (targeted wordlists only).

VRAM coexistence with CT 120: each card is 8 GB. A 3B Ollama model pins ~2.5 GB on card 0 (renderD128). Keep Ollama keep-alive at `1h` so card 0 frees when idle and let hashcat use both cards; or pin Ollama (`OLLAMA_KEEP_ALIVE=-1`) and run hashcat on card 1 only (`HASHCAT_GPU_DEVICES=2`), halving throughput to ~4 GH/s MD5.

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `vulkaninfo` OK as root, 0 devices as `ollama` | node group != render, or user not in render | `ls -ln /dev/dri` in CT vs `getent group render`; re-run `10-lxc-gpu.sh -f`; `id ollama` |
| Ollama logs `library=cpu`, no Vulkan lines | backend missing or no device access | `ls /usr/local/lib/ollama/vulkan`; check `OLLAMA_VULKAN` not `0` in `systemctl show ollama -p Environment` |
| llvmpipe listed as an Ollama GPU | Mesa lavapipe ICD enumerated | add `Environment="GGML_VK_VISIBLE_DEVICES=0,1"` to the drop-in |
| `ollama ps` shows `xx%/yy% CPU/GPU` | model + context exceed VRAM | smaller quant, lower `num_ctx`, or let it split across both GPUs |
| `available=` equals `total=` in logs | VRAM estimated (cap not effective) | `getcap /usr/local/bin/ollama`; expected limitation in unprivileged CTs, scheduler falls back to estimates |
| hashcat benchmarks the CPU, GPUs `skipped` | used `-D 1` (backend type) instead of `-d 1,2` (device number) | use the `hashcat-gpu` wrapper, or `-d 1,2` |
| hashcat shows no GPU at all | `RUSTICL_ENABLE` unset (Rusticl is opt-in) | `grep RUSTICL /etc/environment`; wrapper sets it |
| `CL_OUT_OF_RESOURCES` on a real run | Rusticl ~2 GB single-allocation cap on Polaris | add `-n 128` or lower; not needed for `-b` |
| GPU disappears / ring timeout in dmesg | power, thermals, PCIe link | `journalctl -k | grep amdgpu`; check temps/power in preflight; PSU headroom for 2x RX 580 (~185 W each) |
| CT start fails after `pct set` | stale device path | `pct config <id>`; `ls /dev/dri`; re-run `10-lxc-gpu.sh -f` |

## 10. Rollback

```bash
pct shutdown <CTID>
cp /root/lxc-conf-backup/<CTID>.conf.<timestamp> /etc/pve/lxc/<CTID>.conf     # or: pct set <CTID> --delete dev0,dev1
pct start <CTID>
pct exec <CTID> -- sh -c 'systemctl disable --now ollama; rm -rf /etc/systemd/system/ollama.service.d/10-radeon-vulkan.conf /usr/local/lib/ollama /usr/local/bin/ollama; systemctl daemon-reload'
# host cleanup is not reversible by script; 05-host-cleanup.sh prints exactly what it removes
```
