#!/usr/bin/env bash
# hashcat on both RX 580s via Mesa Rusticl (OpenCL). Runs INSIDE the Kali CT.
# Rusticl is opt-in per driver, so RUSTICL_ENABLE=radeonsi is mandatory or no GPU enumerates.
# -d 1,2 selects the two GPU devices by number (NOT -D, which selects backend TYPE and also
#  matches the PoCL CPU device). CUDA/HIP are ignored so startup is quick and quiet.
#
# Usage: hashcat-gpu.sh <normal hashcat args>
#   benchmark one mode:   hashcat-gpu.sh -b -m 22000
#   crack:                hashcat-gpu.sh -m 22000 capture.hc22000 wordlist.txt -w 3
#
# Rusticl on Polaris caps a single allocation at ~2047 MB (full 8 GB is usable across buffers).
# Large wordlists/masks can exceed that per-kernel; if a real run errors with CL_OUT_OF_RESOURCES
# or an allocation failure, add -n 128 (or lower) to shrink kernel-accel. -n is rejected under -b.
set -u
export RUSTICL_ENABLE=radeonsi
DEVS=${HASHCAT_GPU_DEVICES:-1,2}   # override to "2" to leave card 0 (renderD128) for Ollama
exec hashcat -d "$DEVS" --backend-ignore-cuda --backend-ignore-hip "$@"
