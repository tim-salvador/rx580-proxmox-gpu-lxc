# rx580-proxmox-gpu-lxc

Originally published at https://www.timsalvador.com/blog/rx580-proxmox-gpu-lxc/

Share a pair of AMD Radeon RX 580 (Polaris / gfx803) GPUs into **unprivileged Proxmox LXCs** for two workloads at once:

- **Ollama** (local LLMs) via **Mesa RADV / Vulkan**
- **hashcat** (password cracking) via **Mesa Rusticl / OpenCL**

No ROCm (dropped for Polaris), no proprietary driver, no DKMS. The in-tree `amdgpu` driver plus render-node passthrough means kernel upgrades don't break the GPU path.

> Built and validated on Proxmox VE 9.2 (Debian 13 / trixie, kernel 7.0.x-pve) with 2x PowerColor RX 580 8GB (`1002:67df`). The scripts are hardware-agnostic within the AMD Polaris/Vulkan family but the benchmarks and defaults assume this setup.

**📖 The full story, including the dead ends and lessons, is at [timsalvador.com/blog/rx580-proxmox-gpu-lxc](https://www.timsalvador.com/blog/rx580-proxmox-gpu-lxc/) and in [docs/writeup.md](docs/writeup.md).** It reads as a blog post and doubles as a build log.

---

## Results

Two RX 580s, measured on this host (CPU is an i7-4790K for comparison):

| Ollama (Vulkan/RADV) | Speed |
|---|---|
| llama3.2:3b | ~61 tok/s (single card) |
| llama3.1:8b | ~29 tok/s (single card) |
| qwen2.5:14b | ~7 tok/s (split across both cards, 16GB) |

| hashcat (OpenCL/Rusticl) | 2x RX 580 | i7-4790K | Gain |
|---|---|---|---|
| MD5 | 8,123 MH/s | 91 MH/s | ~89x |
| NTLM | 3,301 MH/s | 102 MH/s | ~32x |
| SHA1 | 3,801 MH/s | 55 MH/s | ~69x |
| WPA2 | 293 kH/s | 4 kH/s | ~72x |
| bcrypt | 19,043 H/s | 1,091 H/s | ~17x |

---

## What's here

```
scripts/        the check -> act -> verify tooling (see scripts/RUNBOOK.md)
docs/           the writeup (Markdown) and image folder
```

`scripts/RUNBOOK.md` is the operational reference: every phase, every command, troubleshooting, and rollback.

```
scripts/
  lib.sh                 shared helpers (GPU discovery, sysfs readers, CT parsing)
  00-preflight.sh        read-only host audit (run first, and after every change)
  05-host-cleanup.sh     remove ROCm/AMDVLK/amdgpu-install leftovers (dry-run by default)
  10-lxc-gpu.sh          pass render nodes into a CT with the CT's own render GID
  20-ct-ollama.sh        install Mesa RADV + pinned Ollama (Vulkan) in the CT
  30-validate.sh         wiring + Vulkan (root & service user) + inference benchmark
                         + host-side GPU-vs-CPU proof
  60-ct-hashcat.sh       install Rusticl + GPU hashcat in a Kali/Debian CT
  ct/                    scripts pushed into the containers
```

---

## Quick start

Run everything from the Proxmox host as root.

```bash
git clone https://github.com/tim-salvador/rx580-proxmox-gpu-lxc.git
cd rx580-proxmox-gpu-lxc/scripts
chmod +x *.sh ct/*

# 1. Audit the host (read-only, changes nothing)
./00-preflight.sh | tee /root/preflight-$(date +%F).log

# 2. Remove any leftovers from an earlier amdgpu-install / ROCm attempt
./05-host-cleanup.sh          # dry run; add -x to apply

# 3. Pass both GPUs into your Ollama CT, then install + validate
pct shutdown <CTID>
./10-lxc-gpu.sh -c <CTID>
./20-ct-ollama.sh -c <CTID> -v 0.40.13 -l 0.0.0.0:11434
./30-validate.sh -c <CTID>    # full benchmark; -B for wiring checks only

# 4. (Optional) GPU hashcat in a Kali/Debian CT
./10-lxc-gpu.sh -c <KALI_CTID>
./60-ct-hashcat.sh -c <KALI_CTID> -b
```

See **[scripts/RUNBOOK.md](scripts/RUNBOOK.md)** for the detailed, per-phase walkthrough and troubleshooting.

---

## Design principles

The scripts exist because wiring this by hand is error-prone and the failure modes are subtle. Every one follows **check -> act -> verify**:

- **Read-only first.** `00-preflight.sh` tells you the truth about the host before anything is installed.
- **Stop on the first failed precondition**, with a message that points at the fix.
- **Validate real GPU work**, not mere enumeration. `30-validate.sh` samples the host's `gpu_busy_percent` *during* a benchmark, so a run that's secretly on the CPU can't pass. It also checks Vulkan as the *service user*, not just root.
- **Guard destructive ops.** `05-host-cleanup.sh` simulates its purge and aborts if any `proxmox*`/`pve*`/`lxc*`/`qemu*` package would be collateral, and never runs `apt autoremove`.
- **Refuse known landmines.** The CT installer stops if it finds leftover ROCm apt sources or `/opt/amdgpu` linker paths that would shadow Debian's libraries.

All scripts pass `shellcheck` at warning level.

---

## Requirements

- Proxmox VE 9.x (Debian 13 base), in-tree `amdgpu` driver (default)
- AMD Polaris GPU(s) bound to `amdgpu` (not `vfio-pci`, not reserved for a VM)
- Target containers: Debian 12/13 or Ubuntu 22.04/24.04 (not Alpine; Mesa needs glibc)
- No SSD required, but see the writeup: cold model-load time is disk-bound, and on a spinning disk it's slow (keep models resident with `OLLAMA_KEEP_ALIVE=-1`)

---

## Caveats, in brief

- **No ROCm** on Polaris/gfx803. Mesa (RADV + Rusticl) is the only path. This is the whole point of the repo.
- **Rusticl caps single allocations at ~2GB** on Polaris; large hashcat workloads may need `-n` tuning.
- **hashcat's native Vulkan backend does not enumerate** these cards; use OpenCL/Rusticl (`-d 1,2`, not `-D 1`).
- **Model cold-load is slow on HDD-backed storage** and is not fixable in software; an SSD is the only structural fix.
- Local small models (3B/8B) are **mediocre at tool-calling**; for Home Assistant, let the native intent engine drive devices and use the LLM for conversation.

Full detail on all of these in the writeup.

---

## License

MIT. See [LICENSE](LICENSE).

## Author

Tim Salvador · [timsalvador.com](https://timsalvador.com) · [github.com/tim-salvador](https://github.com/tim-salvador) · [linkedin.com/in/tim-salvador](https://linkedin.com/in/tim-salvador)
