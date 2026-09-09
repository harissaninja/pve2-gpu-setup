#!/bin/bash
# ============================================================
# pve2-host-nvidia-setup.sh
# NVIDIA driver 580.x for kernel 7.0.14-16-pve — HOST side only
# Run as root on pve2. Reboot required between phases 2 and 3.
# ============================================================
set -euo pipefail

PHASE="${1:-help}"

case "$PHASE" in

# ------------------------------------------------------------
pre)
  # Phase 0 — sanity checks (no changes)
  echo "== GPU =="
  lspci -nnk | grep -iA3 nvidia || true
  echo "== running kernel (expect 7.0.14-16-pve) =="
  uname -r
  echo "== secure boot (must be disabled) =="
  mokutil --sb-state 2>/dev/null || echo "mokutil not present; check UEFI settings manually"
  echo "== headers present? =="
  ls /usr/src/ | grep -q "pve" && ls /usr/src/ || echo "NO HEADERS — phase 1 will install pve-headers"
  echo "== currently bound driver (nouveau expected) =="
  lspci -nnk -s 01:00.0 | grep "Kernel driver"
  echo "Review the above, then run: $0 1"
  ;;

# ------------------------------------------------------------
1)
  # Phase 1 — purge broken Debian nvidia stack + install prerequisites
  echo "== purging half-installed Debian NVIDIA packages =="
  apt remove --purge -y '^nvidia-.*' '^libnvidia-.*' || true
  apt autoremove --purge -y
  apt autoclean

  echo "== build prerequisites =="
  apt update
  apt install -y build-essential dkms pve-headers wget

  echo "== blacklist nouveau AND nova =="
  cat > /etc/modprobe.d/blacklist-nvidia-nouveau.conf <<'EOF'
blacklist nouveau
blacklist nova
options nouveau modeset=0
EOF
  update-initramfs -u -k all

  echo "Done. REBOOT REQUIRED before phase 2."
  echo "After reboot run: $0 2"
  ;;

# ------------------------------------------------------------
2)
  # Phase 2 — download driver + apply kernel 7.0 patches + DKMS install
  # Must run AFTER reboot (nouveau/nova must not hold the card).
  echo "== confirming no nouveau/nova loaded =="
  if lsmod | grep -qiE '^(nouveau|nova) '; then
    echo "ERROR: nouveau/nova still loaded. Reboot again or check blacklist."; exit 1
  fi
  if lspci -nnk -s 01:00.0 | grep -i 'kernel driver in use' | grep -qiE 'nouveau|nova'; then
    echo "ERROR: nouveau/nova still bound to GPU. Reboot again or check blacklist."; exit 1
  fi

  DRIVERVER="${DRIVERVER:-580.159.03}"
  RUNFILE="NVIDIA-Linux-x86_64-${DRIVERVER}.run"
  cd /root

  if [ ! -f "$RUNFILE" ]; then
    echo "== downloading $RUNFILE =="
    wget -q "https://download.nvidia.com/XFree86/Linux-x86_64/${DRIVERVER}/${RUNFILE}"
    chmod +x "$RUNFILE"
  fi

  if [ -f "NVIDIA-Linux-x86_64-${DRIVERVER}-tmp/kernel/nvidia-installer" ] || \
     [ -d "NVIDIA-Linux-x86_64-${DRIVERVER}-tmp/kernel" ]; then
    echo "== existing extracted tree found, keeping it (preserves applied patches) =="
  else
    echo "== extracting =="
    bash "$RUNFILE" -x --target "NVIDIA-Linux-x86_64-${DRIVERVER}-tmp"
  fi
  cd "NVIDIA-Linux-x86_64-${DRIVERVER}-tmp"

  echo "== applying vmflags patch if not already applied =="
  if ! grep -q 'vm_flags_reset' kernel/common/inc/nv-mm.h; then
    if [ -f nvidia-7.0-vmflags-580.159.03.patch ]; then
      patch -d kernel -p1 < nvidia-7.0-vmflags-580.159.03.patch
    else
      echo "WARNING: patch file missing and vm_flags_reset absent — build will likely fail"
      read -rp "Continue anyway? [y/N] " pc; [ "$pc" = "y" ] || exit 1
    fi
  else
    echo "patch already applied, skipping"
  fi

  echo "== PATCH REQUIRED =="
  cat <<'NOTE'
Kernel 7.0 breaks the 580 build. Before running the installer you must
apply the community patches:
  https://github.com/harissaninja/pve2-gpu-setup — nvidia-7.0-vmflags-580.159.03.patch
  - VMA API change   (nv-mm.h / nv-mmap.c)
  - dma-fence helper (nvidia-dma-fence-helper.h)
  - __vm_flags removal (kernel >= 7.0.2 — we are on 7.0.14: REQUIRED)
  - strlcpy removal  (affects 580.x)
Download the .patch files, copy them into this directory, and register
them in dkms.conf via PATCH[]/PATCH_MATCH[] entries, then continue.
NOTE
  read -rp "Patches applied? [y/N] " ok
  [ "$ok" = "y" ] || { echo "Aborting — apply patches first."; exit 1; }

  echo "== running installer (DKMS, headless) =="
  ./nvidia-installer --dkms -s \
    --no-questions --no-x-check --no-nouveau-check
  # Answer No to X config when prompted — headless hypervisor.

  echo "== module load config =="
  cat > /etc/modules-load.d/nvidia.conf <<'EOF'
nvidia
nvidia-uvm
nvidia-modeset
EOF

  echo "== persistenced =="
  systemctl enable --now nvidia-persistenced 2>/dev/null || true
  ;;

# ------------------------------------------------------------
3)
  # Phase 3 — verification
  echo "== dkms status =="
  dkms status
  echo "== nvidia-smi =="
  nvidia-smi
  echo "== device nodes (note major numbers: normally 195 and 511) =="
  ls -l /dev/nvidia* 2>/dev/null || echo "no /dev/nvidia* — try: nvidia-modprobe -u -c 0; nvidia-smi"
  echo "== module loaded =="
  lsmod | grep nvidia
  echo
  echo "If all four passed: HOST SIDE COMPLETE."
  echo "Next: run the LXC config steps (see lxc-guest-steps.md), then reboot the CT."
  ;;

help|*)
  cat <<EOF
Usage: $0 {pre|1|2|3}
  pre  — sanity checks only (no changes)
  1    — purge broken nvidia packages, install build deps, blacklist nouveau/nova, then REBOOT
  2    — download+extract 580 driver, apply kernel-7.0 patches (interactive prompt), DKMS install
  3    — verify: dkms status, nvidia-smi, /dev/nvidia*, lsmod
EOF
  ;;
esac
