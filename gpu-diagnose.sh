#!/bin/bash
# ============================================================
# gpu-diagnose.sh — GPU passthrough self-diagnostics for pve2
#
# Run ON THE HOST as root:      bash gpu-diagnose.sh
# Run for the CT from the host: bash gpu-diagnose.sh ct
# Run both in one go:           bash gpu-diagnose.sh all
#
# Output goes to the terminal AND to a timestamped log file
# (/tmp/gpu-diagnose-<UTC>.log on the host, /tmp/gpu-diagnose-ct-<UTC>.log
# inside the CT). Send the whole log when asking for help — every
# check below is one that has historically failed on this setup.
#
# This script is READ-ONLY. It changes nothing.
# ============================================================
set -u
MODE="${1:-all}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HOSTLOG="/tmp/gpu-diagnose-${STAMP}.log"
CTLOG="/tmp/gpu-diagnose-ct-${STAMP}.log"
CTID=100

run_host() {
  exec > >(tee "$HOSTLOG") 2>&1
  echo "=========================================================="
  echo "GPU DIAGNOSE — HOST pve2 — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "log: $HOSTLOG"
  echo "=========================================================="

  echo; echo "--- [1] kernel (expect 7.0.14-16-pve) ---"
  uname -r

  echo; echo "--- [2] GPU binding (must say 'Kernel driver in use: nvidia'; nouveau/nova = FAIL, see runbook T5) ---"
  lspci -nnk -s 01:00.0

  echo; echo "--- [3] DKMS status (want 'nvidia/580.159.03 ... installed' for $(uname -r); MISSING = see T3) ---"
  dkms status 2>&1 || echo "dkms not found"

  echo; echo "--- [4] nvidia-smi header (want: Driver Version: 580.159.03, CUDA Version: 13.0; FAILS = see T3/T5) ---"
  nvidia-smi 2>&1 | head -12 || true

  echo; echo "--- [5] device nodes + majors (want nvidia0+nvidiactl major 195, nvidia-uvm major 510; MISSING = runbook A3 note) ---"
  ls -l /dev/nvidia* 2>&1 || echo "NO /dev/nvidia* — try: nvidia-modprobe -u -c 0 && nvidia-smi"

  echo; echo "--- [6] loaded modules (want nvidia + nvidia_uvm + nvidia_modeset) ---"
  lsmod | grep -E '^nvidia' || echo "NO nvidia modules loaded"

  echo; echo "--- [7] modules-load config (want 3 lines: nvidia, nvidia-uvm, nvidia-modeset; MISSING = won't survive reboot, see T4) ---"
  cat /etc/modules-load.d/nvidia.conf 2>&1

  echo; echo "--- [8] persistenced (want 'active (running)'; dead = T4) ---"
  systemctl is-active nvidia-persistenced 2>&1; systemctl status nvidia-persistenced --no-pager 2>&1 | head -5 || true

  echo; echo "--- [9] blacklist file (want: blacklist nouveau, blacklist nova, options nouveau modeset=0; MISSING = T5) ---"
  cat /etc/modprobe.d/blacklist-nvidia-nouveau.conf 2>&1

  echo; echo "--- [10] CT 100.conf GPU lines (want cgroup2 allows c 195:* and c 510:*, four mount.entry lines; WRONG MAJOR = see T1b) ---"
  grep -E 'nvidia|NVIDIA|195|510|511' /etc/pve/lxc/${CTID}.conf 2>&1 || echo "no GPU lines found in /etc/pve/lxc/${CTID}.conf"

  echo; echo "--- [11] CT running? (needed for 'ct' mode) ---"
  pct status ${CTID} 2>&1

  echo; echo "--- [12] the .run installer present on host? (needed if CT userspace must be reinstalled) ---"
  ls -l /root/NVIDIA-Linux-x86_64-580.159.03.run 2>&1

  echo; echo "=========================================================="
  echo "HOST diagnose complete. Log: $HOSTLOG"
  echo "=========================================================="
}

run_ct() {
  # executes INSIDE the CT via pct exec; log lands on the CT's /tmp
  pct exec ${CTID} -- bash -s "${CTLOG}" <<'CTEOF'
  exec > >(tee "$1") 2>&1
  echo "=========================================================="
  echo "GPU DIAGNOSE — CT ${HOSTNAME:-hermesagent} — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "log: $1"
  echo "=========================================================="

  echo; echo "--- [C1] device nodes (want nvidia0, nvidiactl, nvidia-uvm, nvidia-uvm-tools; MISSING = T1c) ---"
  ls -l /dev/nvidia* 2>&1 || echo "NO /dev/nvidia* inside CT"

  echo; echo "--- [C2] nvidia-smi (want same header as host: 580.159.03 / GTX 950M; 'couldn't communicate' = T1) ---"
  nvidia-smi 2>&1 | head -12 || true

  echo; echo "--- [C3] libcuda.so.1 (want a path in /usr/lib/...; MISSING = T2) ---"
  ldconfig -p | grep -E 'libcuda\.so|libnvidia-ml|libnvidia-encode' || echo "libcuda/libnvidia-ml/libnvidia-encode NOT in ldconfig cache"

  echo; echo "--- [C4] userspace version (want 580.159.03; MISMATCH with host = T1a) ---"
  nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>&1 || true

  echo; echo "--- [C5] CUDA probe (want 'CUDA OK'; fail = T2) ---"
  python3 - <<'PYEOF' 2>&1 || true
import ctypes
try:
    cuda = ctypes.CDLL("libcuda.so.1")
    assert cuda.cuInit(0) == 0, "cuInit failed"
    ctx = ctypes.c_void_p()
    dev = ctypes.c_int()
    cuda.cuDeviceGet(ctypes.byref(dev), 0)
    assert cuda.cuCtxCreate_v2(ctypes.byref(ctx), 0, dev) == 0, "cuCtxCreate failed"
    free, total = ctypes.c_size_t(), ctypes.c_size_t()
    cuda.cuMemGetInfo_v2(ctypes.byref(free), ctypes.byref(total))
    print(f"CUDA OK — device 0, VRAM free/total: {free.value//1048576}/{total.value//1048576} MiB")
except Exception as e:
    print(f"CUDA FAIL — {e}")
PYEOF

  echo; echo "--- [C6] NVENC probe (want 'NVENC OK'; fail = userspace install incomplete) ---"
  python3 - <<'PYEOF' 2>&1 || true
import ctypes
try:
    enc = ctypes.CDLL("libnvidia-encode.so.1")
    r = enc.NvEncodeAPICreateInstance()
    print("NVENC OK" if r == 0 else f"NVENC FAIL — NvEncodeAPICreateInstance returned {r}")
except Exception as e:
    print(f"NVENC FAIL — {e}")
PYEOF

  echo; echo "--- [C7] env vars (want NVIDIA_VISIBLE_DEVICES=all and NVIDIA_DRIVER_CAPABILITIES=compute,utility,video) ---"
  grep -E 'NVIDIA_' /etc/environment 2>&1 || echo "no NVIDIA_ vars in /etc/environment"
  env | grep -E '^NVIDIA_' || echo "(no NVIDIA_ vars in this shell — normal; they live in /etc/environment for login shells)"

  echo; echo "--- [C8] torch (want True + GTX 950M; import error = not installed; False = T6) ---"
  python3 - <<'PYEOF' 2>&1 || true
try:
    import torch
    print(torch.__version__, "| cuda available:", torch.cuda.is_available(), "|", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "-")
except ImportError:
    print("torch not installed (optional)")
except Exception as e:
    print(f"torch present but CUDA check failed: {e}")
PYEOF

  echo; echo "--- [C9] kernel module build tools present in CT? (should be ABSENT — CT must never build modules) ---"
  command -v dkms || echo "dkms: absent (correct)"

  echo; echo "=========================================================="
  echo "CT diagnose complete. Log: $1"
  echo "=========================================================="
CTEOF
  echo "CT log also retrievable with: pct pull ${CTID} ${CTLOG} /tmp/ct-diagnose-${STAMP}.log"
}

case "$MODE" in
  host) run_host ;;
  ct)   run_ct ;;
  all)  run_host; run_ct ;;
  *) echo "usage: bash gpu-diagnose.sh [host|ct|all]  (default: all)" ;;
esac
