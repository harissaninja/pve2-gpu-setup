# REVIEW PROMPT — paste this entire file (with the files below appended)
# into an independent LLM (Claude Opus / GLM 5.3 / GPT-5.6 / DeepSeek V4)
# to get an unbiased critique of the pve2 GPU passthrough guide.
#
# The author of these files is an AI agent; a second opinion from a
# different model is wanted precisely to catch its blind spots.

You are reviewing a GPU passthrough setup guide for correctness, completeness,
and safety. Treat it as hostile-review: your job is to find what's WRONG,
MISSING, or DANGEROUS, not to praise it.

## Context (fixed facts — do not challenge these, they are verified)

- Host "pve2": HP laptop, i7-6700HQ, Proxmox VE 9 (Debian 13 trixie base),
  kernel 7.0.14-16-pve. Intel HD 530 iGPU drives the console.
- GPU: NVIDIA GTX 950M (GM107, Maxwell, sm_50, 4 GB VRAM, PCI 01:00.0).
- Maxwell support ends at driver branch 580; nvidia-open does NOT support
  Maxwell. Only the proprietary 580.x with a __vm_flags kernel patch builds
  on this kernel. Verified: driver 580.159.03, nvidia-uvm device major is
  510 (not the common 511).
- Guest: LXC container (not a VM), VMID 100 "hermesagent", Debian 13.
  Device-sharing architecture (host driver + /dev/nvidia* bind-mounts),
  NOT VFIO — VFIO was rejected deliberately (LXC can't VFIO; single GPU).
- CURRENT STATE: everything is installed and VERIFIED WORKING end-to-end
  (nvidia-smi, CUDA context, NVENC, torch cu121 all pass inside the CT).
- The user plans to possibly WIPE the host and rebuild from scratch,
  following the guide's PART 0 sequence: Proxmox install → community-scripts
  post-install (may dist-upgrade) → GPU host setup → create/restore CT →
  CT GPU steps.

## Your review criteria (address each, cite file + line/section)

A. CORRECTNESS OF COMMANDS — any command that would fail, hang, or do
   something different than the guide claims. Check bash syntax, paths,
   flag names (--no-kernel-module vs --no-kernel-modules), pct syntax,
   lxc.cgroup2 device rule format, sed/awk snippets.

B. ORDERING / DEPENDENCY BUGS — steps that reference prerequisites not
   yet created (CT exists? driver loaded? file pushed?). Pay special
   attention to PART 0's claimed order and whether anything in PART A/B
   contradicts it.

C. INTERNAL CONTRADICTIONS — guide vs script vs diagnose script. E.g.
   device majors, driver version strings, patch counts, kernel-version
   expectations, file paths that differ between files.

D. SAFETY / DESTRUCTIVENESS — any step that could brick networking,
   lock the user out, destroy data, or wedge dpkg/apt, especially during
   the fresh-rebuild path. Flag missing backups/warnings.

E. COMPLETENESS FOR THE REBUILD SCENARIO — if a person formatted the
   host and had ONLY this repo, could they get back to the verified
   working state? List anything assumed-but-not-written (network config?
   users? Secure Boot? BIOS? VMID? storage?).

F. DIAGNOSTIC SCRIPT QUALITY — does gpu-diagnose.sh actually distinguish
   the failure modes the runbook claims it does? Any checks that would
   false-pass or false-fail? Any quoting/subshell bugs in the script?

G. MISSED MAINTENANCE RISKS — what breaks on: PVE kernel upgrade, NVIDIA
   580.x point release, CT restore to a new VMID, unprivileged vs
   privileged CT switch.

Output format:
- For each finding: [severity: BLOCKER|MAJOR|MINOR|NIT] [file:section]
  one-paragraph explanation + concrete fix.
- End with a verdict: "guide is rebuild-safe: YES/NO" and the 3 most
  important fixes ranked.

Do not suggest architectural changes (VFIO, VM conversion, newer GPU,
different driver branch) — those decisions are settled.

## FILES TO REVIEW (below)
# pve2 NVIDIA → hermesagent LXC: step-by-step runbook

Two artifacts:
- pve2-host-nvidia-setup.sh  → all HOST steps, phases 0-3
- this file                  → full ordered checklist with the LXC part

==========================================================
WHERE THINGS RUN — quick reference
==========================================================

ON THE HOST (pve2, SSH as root):
  - fetch + run pve2-host-nvidia-setup.sh (phases pre / 1 / 2 / 3)
  - edit /etc/pve/lxc/100.conf        (cgroup + mount entries)
  - pct stop 100 / pct start 100      (config only applies on restart)
  - pct push 100 <host-file> <ct-path>  (copy files INTO the CT)
  - anything touching /dev/nvidia*, dkms, modprobe, initramfs, GRUB
  - pve-headers, driver kernel modules, nvidia-persistenced

INSIDE THE CT (hermesagent, pct enter 100 or SSH):
  - install the driver USERSPACE ONLY: .run --no-kernel-module
  - pip/python/torch, ffmpeg, llama.cpp, application workloads
  - nvidia-container-toolkit + Docker config (if using Docker)
  - env vars for containers: NVIDIA_VISIBLE_DEVICES / _CAPABILITIES
  - NEVER run DKMS / modprobe / kernel-module builds inside the CT

Rule of thumb: kernel + devices + config = HOST; libraries + apps = CT.

==========================================================
PART 0 — FRESH HOST REBUILD (after formatting / new Proxmox install)
==========================================================
ORDER MATTERS. Do these in sequence; each step assumes the previous
one finished. Do NOT create the CT before the host driver works.

P0.1  Install Proxmox VE (latest stable). In UEFI: confirm Secure Boot
      is DISABLED before first boot (DKMS module is self-signed via MOK;
      a Secure-Boot-enabled install will refuse to load it).

P0.2  Run the community-scripts Proxmox VE post-install script:
      bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"
      Choose: correct sources → yes; disable enterprise repos → yes;
      enable no-subscription → yes; disable HA/corosync → yes (single node);
      update Proxmox VE → YES.
      *** This runs apt dist-upgrade and may change the PVE kernel. ***
      Reboot when it offers. After reboot note the kernel:
      uname -r
      If it is NOT 7.0.14-16-pve, remember it — every hardcoded kernel
      check in this runbook and in pve2-host-nvidia-setup.sh refers to
      the kernel that is RUNNING when you build the driver.

      --------------------------------------------------------------
      DIST-UPGRADE CHECKPOINT (read before Part A)
      --------------------------------------------------------------
      A PVE kernel bump is unlikely (PVE pins its kernel and the
      post-install script mostly applies security updates), but if it
      happens, adjust the steps below BEFORE running Part A. A kernel
      bump does NOT invalidate the plan — it only touches the parts
      that reference kernel internals.

      Check what changed:
        uname -r                                  # new running kernel
        apt list --installed 2>/dev/null | grep -E 'pve-kernel|proxmox-kernel'
      Also check whether the NVIDIA driver version you're about to
      install is still the newest 580.x (a rebuild is a good moment to
      update): https://download.nvidia.com/XFree86/Linux-x86_64/
      (580.x is the LAST branch for Maxwell — never go above 580.)

      Code adjustments required if the kernel changed:

      ADJ-1. A0 "expect 7.0.14-16-pve" — read as "expect the kernel
             you just recorded". The script's `pre` phase prints
             uname -r; just verify it matches what you recorded.

      ADJ-2. A2 vmflags patch — REQUIRED only on kernels >= 7.0.2
             (which includes any future 7.0.x/7.1+). If the new kernel
             is 7.1+ or later, the patch may fail to apply cleanly:
               cd /root/pve2-gpu-setup
               # test without committing:
               patch -d NVIDIA-Linux-x86_64-580.*/kernel --dry-run -p1 \
                 < nvidia-7.0-vmflags-580.159.03.patch
             If the dry-run fails, check whether __vm_flags handling
             changed (grep for vm_flags_reset in the kernel's
             include/linux/mm.h); a dry-run success means no action
             needed. Diagnostics if the BUILD then fails: runbook T3.

      ADJ-3. A1 nova blacklist line — `blacklist nova` is only needed
             on kernels that ship the Rust nova driver (7.0+). Harmless
             if absent in future kernels; leave it.

      ADJ-4. A3 / B2 device majors — nvidia0/nvidiactl major (195) and
             nvidia-uvm major (510 here) come from the LOADED DRIVER,
             not the kernel; they can change with a DRIVER version
             change. After A2, always re-read them:
               ls -l /dev/nvidia* | awk '{print $5, $6, $NF}'
             (the comma-separated major numbers in the ls output) and
             use THOSE in the two lxc.cgroup2.devices.allow lines in
             B2 — do not trust the 195/510 values printed in this
             runbook blindly.

      ADJ-5. B2 PCI address — 01:00.0 (the GTX 950M's slot) can shift
             if hardware/BIOS changes; after any hardware change:
               lspci -nn | grep -i nvidia
             and use the new address in the runbook's lspci commands
             (T5, gpu-diagnose.sh check [2]).

      Nothing else in the guide is kernel-sensitive. If the kernel did
      NOT change (likely), proceed to Part A with zero adjustments.

P0.3  Fetch this repo onto the fresh host:
      apt install -y git
      git clone https://github.com/harissaninja/pve2-gpu-setup /root/pve2-gpu-setup
      cd /root/pve2-gpu-setup

P0.4  GPU HOST SETUP FIRST — Part A below (A0 → A1 → reboot → A2 → A3).
      Why before the CT:
      - The CT config mounts /dev/nvidia* into the CT. If the host
        driver isn't loaded, lxc.mount.entry ... create=file creates
        EMPTY PLACEHOLDER FILES inside the CT that later BLOCK the real
        device bind-mounts. Host driver first = clean first boot.
      - DKMS builds against the running kernel; do it once, after the
        post-install update, not before.

P0.5  CREATE / RESTORE THE CT. Two paths:
      a. Fresh CT via community-scripts (Debian 13 template), then
         rename/keep VMID 100 (this runbook's CT is VMID 100
         "hermesagent"; a different VMID means editing the pct
         commands and /etc/pve/lxc/<ID>.conf paths throughout Part B).
      b. Restore from vzdump backup of the old CT:
         pct restore 100 /mnt/pve/<storage>/dump/vzdump-lxc-100-*.tar.zst
         (or via the web UI: Storage → backups → Restore; untick
         "Unprivileged" only if the backup was privileged).
      Confirm CT exists: pct list

P0.6  CT GPU STEPS — Part B below (B1 → B8). Then gpu-diagnose.sh all.

P0.7  Remaining from-scratch TODOs not covered by this repo:
      - network/VLAN config, storage mounts, DNS
      - user accounts inside the CT (hermes user, sudo)
      - restoring services (Hermes itself, Docker, etc.)

The rest of this runbook assumes P0 is done and the CT exists.

==========================================================
PART A — HOST pve2 (run as root, in order)
==========================================================

A0. Sanity check (no changes)
    bash pve2-host-nvidia-setup.sh pre
    - confirm GTX 950M shows [10de:139a]
    - confirm kernel is 7.0.14-16-pve
    - confirm Secure Boot is DISABLED (module is self-signed via DKMS MOK)
    - note current driver in use (nouveau expected)

A1. Purge + prerequisites + blacklist           [~5 min]
    bash pve2-host-nvidia-setup.sh 1
    Does:
      - apt purge all half-installed nvidia packages (the failed 550 stack)
      - install build-essential, dkms, pve-headers, wget
      - blacklist nouveau AND nova (Rust nouveau successor binds card first on 7.0)
      - update-initramfs
    Then:
      *** REBOOT ***

A2. Driver install (after reboot)               [~10 min]
    DRIVERVER=580.159.03 bash pve2-host-nvidia-setup.sh 2
    Does:
      - verifies nouveau/nova no longer hold the card
      - downloads NVIDIA-Linux-x86_64-580.159.03.run from download.nvidia.com
      - extracts it
      - PAUSES and asks you to apply kernel-7.0 patches FIRST:
          * source: https://gist.github.com/louzt/1c85044d5090d19223c3f5edf426a19c
          * needed: VMA API fix, dma-fence helper fix, __vm_flags fix (7.0.2+),
            strlcpy fix (580.x)
          * copy .patch files next to the extracted sources, register in
            dkms.conf via PATCH[]/PATCH_MATCH[]
      - after you confirm, runs nvidia-installer --dkms (headless, No X config)
      - sets /etc/modules-load.d/nvidia.conf (nvidia, nvidia-uvm, nvidia-modeset)
      - enables nvidia-persistenced

A3. Host verification
    bash pve2-host-nvidia-setup.sh 3
    PASS criteria — all four:
      1. dkms status → nvidia/580.x ... installed  (for 7.0.14-16-pve)
      2. nvidia-smi → shows GTX 950M
      3. /dev/nvidia0, /dev/nvidiactl, /dev/nvidia-uvm exist
      4. lsmod shows nvidia (+nvidia_uvm after first use)
    If /dev/nvidia* missing: nvidia-modprobe -u -c 0 && nvidia-smi, re-check.
    NOTE the major numbers (normally 195 for nvidia*): they feed the
    cgroup rules in B1. CONFIRMED ON THIS HOST: nvidia-uvm major is 510,
    not 511 (check with: ls -l /dev/nvidia-uvm).
    >>> PART A IS 100% HOST — nothing here runs inside the CT. <<<

==========================================================
PART B — LXC hermesagent (VMID 100) — ONLY AFTER PART A PASSES
==========================================================

B1. [HOST] Stop the container:
    pct stop 100

B2. [HOST] Add to /etc/pve/lxc/100.conf  (use the major numbers from A3; uvm = 510 here):
    lxc.cgroup2.devices.allow: c 195:* rwm
    lxc.cgroup2.devices.allow: c 510:* rwm
    lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
    lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
    lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
    lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file

B3. [HOST] Start container (config applies only on start):
    pct start 100

B4. Install MATCHING userspace in the CT (580.159.03, no kernel module).
    Step 1 [HOST] — deliver the .run into the CT (host /root is not visible in the CT):
    pct push 100 /root/NVIDIA-Linux-x86_64-580.159.03.run /tmp/nvidia.run --perms 644
    Step 2 [CT] — enter the container, then install userspace only:
    pct enter 100
    sudo bash /tmp/nvidia.run --no-kernel-module -s
    Installer warnings about X paths / glvnd EGL config are harmless headless.
    Version must EXACTLY match host (check: nvidia-smi | head -1 in both).

B5. [CT] Environment for CUDA + NVENC (in shell profile, systemd units, or Docker env):
    NVIDIA_VISIBLE_DEVICES=all
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

B6. [CT] Docker inside the CT (only if you use Docker):
    install nvidia-container-toolkit per NVIDIA docs
    if "BPF_CGROUP_DEVICE: operation not permitted":
      set no-cgroups = true in /etc/nvidia-container-runtime/config.toml

B7. [CT] Verification inside container — ALL CONFIRMED WORKING 2026-09-09:
    nvidia-smi                      # driver 580.159.03, GTX 950M, 4096 MiB ✓
    ctypes libcuda smoke test: cuInit/cuCtxCreate/cuMemAlloc OK, 4004/4037 MiB free ✓
    ctypes libnvidia-encode smoke test: NvEncodeAPICreateInstance() = 0 ✓
    torch (cu121 wheel): torch.cuda.is_available() = True, GTX 950M ✓
      (install as root in the CT: apt install python3-pip; pip3 install --index-url
       https://download.pytorch.org/whl/cu121 torch; ~2.5 GB)
    ffmpeg NVENC encode test still to run when transcoding work starts.

B8. [HOST + CT] Full reboot test (host + CT) to confirm persistence across reboots.
    After reboot, verify persistence:
    [HOST] bash pve2-host-nvidia-setup.sh 3        # all four host checks
    [HOST] bash gpu-diagnose.sh all                # full host+CT sweep, log to /tmp
    PASS = CT checks C1–C7 all show expected values; log preserved for comparison.

==========================================================
DO NOT RUN — already tried, known to fail on this setup
==========================================================
Each of these was attempted during this project and diagnosed. Do not
re-run them; the reason they fail is listed so future-you doesn't retry.

1. apt install nvidia-driver nvidia-smi        (Debian 550.163.01 stack)
   FAILS: nvidia-kernel-dkms 550.163.01 cannot build against
   7.0.14-16-pve — make.log shows `struct vm_area_struct has no member
   named __vm_flags`, implicit `in_irq`, and missing
   `dma_map_ops.map_resource`. All removed/renamed after 550 was
   written. No headers fix helps. Also drags ~540 MB of X11/GTK onto
   the hypervisor. This stack was purged in Phase A1.

2. Driver branch 595/610 (researched suggestion)
   WRONG for this card: 580 is the LAST branch supporting Maxwell
   (GTX 950M). 595+ dropped Maxwell entirely. Don't chase newer branches.

3. nvidia-open kernel modules
   NOT AN OPTION: open modules don't support Maxwell (sm_50) at all.
   The proprietary 580 with kernel-7.0 patches is the only path.

4. VFIO/PCI passthrough (IOMMU + GRUB + vfio-pci + blacklist nvidia
   recipe from YouTube-style guides)
   WRONG ARCHITECTURE: that's for passing a GPU into a VM. It binds the
   card to vfio-pci, which removes /dev/nvidia* from the host — fatal
   for LXC sharing, which works by mounting the HOST's /dev/nvidia*
   into the CT. Also pointless here: hermesagent is an LXC, and LXC
   cannot do VFIO. Never blacklist `nvidia` on this host.

5. lxc.hook.mount / nvidia-container-cli hook in 100.conf
   BROKEN on PVE 9: use the manual cgroup2 allow + mount.entry lines
   in B2 (verified working).

6. c 511:* rwm for nvidia-uvm (the "normal" major from generic guides)
   FAILS on this host: nvidia-uvm got major 510 here. Rule for 511
   allows nothing — device access dies inside the CT with no visible
   error other than failed CUDA init. Always read the major from
   `ls -l /dev/nvidia-uvm` on the host after a fresh driver load.

7. bash /root/NVIDIA-Linux-x86_64-580.159.03-tmp/....run  (inside CT)
   FAILS twice over: host /root is not visible in the CT, and the -tmp
   dir contains only the extracted tree, not the .run. Deliver via
   `pct push` from the actual path (see B4).

8. pip3 install ...  (as non-root in the CT without python3-pip)
   FAILS: trixie base image has no pip module and agent users have no
   passwordless sudo. As root: `apt install python3-pip` first, then
   `pip3 install --index-url https://download.pytorch.org/whl/cu121 torch`.

9. Kernel-7.0 patch set as published in the louzt gist (all 4 patches)
   PARTIALLY OBSOLETE for 580.159.03: only the __vm_flags patch is
   needed. strlcpy and dma-fence fixes are already resolved in this
   driver rev (verified by grep), and the VMA API fix is not triggered.
   Applying extras is harmless but unnecessary; the repo's
   nvidia-7.0-vmflags-580.159.03.patch is the minimal verified set.

==========================================================
TROUBLESHOOTING — check in this order
==========================================================

STEP 0 — before anything else, run the diagnostics and keep the log:
    bash gpu-diagnose.sh all          # on pve2 host (as root)
    One run collects every check below on both host and CT, writes a
    timestamped log to /tmp/gpu-diagnose-*.log, and labels each check
    with the expected value and the T-entry that covers it if wrong.
    When reporting a problem, attach that log — no manual probing needed.

T1. nvidia-smi works on host but NOT in CT ("couldn't communicate"):
    a. [CT + HOST] Driver version mismatch — `nvidia-smi | head -1` on BOTH
       host and CT. Userspace in CT must EXACTLY match the host kernel
       module version (580.159.03). Reinstall in CT with --no-kernel-module.
    b. [HOST] Wrong/missing cgroup rule:
       `ls -l /dev/nvidia-uvm`  → confirm major (here: 510)
       `cat /etc/pve/lxc/100.conf | grep cgroup2` → majors 195 and 510
       Rules only apply on CT start: `pct stop 100 && pct start 100`.
    c. [CT] Device nodes missing — check the four lxc.mount.entry
       lines are present (host-side config); then `ls /dev/nvidia*` inside the CT.

T2. CUDA apps fail in CT but nvidia-smi works:
    - [CT] libcuda.so.1 missing → userspace not installed, or wrong
      version. `ldconfig -p | grep libcuda` inside CT.
    - [HOST] /dev/nvidia-uvm exists but stale (created before host driver
      loaded) → `rm /dev/nvidia-uvm && nvidia-modprobe -u -c 0`
      then restart the CT (HOST: pct stop/start 100).

T3. DKMS rebuild fails after a PVE kernel upgrade:   [HOST]
    - `apt install pve-headers` (meta-package tracks the new kernel)
    - If kernel > 7.0.14: the __vmflags patch may need rework — check
      nv-mm.h / nv.c errors in /var/lib/dkms/nvidia/*/build/make.log.
    - Fallback: boot the previous PVE kernel from the boot menu.

T4. After reboot, card idle at 100% memory clock / persistenced dead:   [HOST]
    - `systemctl status nvidia-persistenced`
    - `cat /etc/modules-load.d/nvidia.conf` must list nvidia, nvidia-uvm,
      nvidia-modeset. If /dev/nvidia-uvm is missing after boot:
      `nvidia-modprobe -u -c 0` (then T2 note above).

T5. Nouveau/nova re-grabbed the card (after kernel or firmware update):   [HOST]
    - `lspci -nnk -s 01:00.0 | grep "Kernel driver"` → must say nvidia
    - If nouveau: `cat /etc/modprobe.d/blacklist-nvidia-nouveau.conf`
      must contain blacklist nouveau, blacklist nova, modeset=0;
      then `update-initramfs -u -k all` and reboot.

T6. Torch/PyTorch "CUDA not available" in CT:   [CT]
    - `python3 -c "import torch; print(torch.version.cuda,
      torch.cuda.is_available())"` — if False but B5 ctypes test passes,
      the wheel's bundled runtime needs a matching driver at least as
      new; driver 580.159.03 (CUDA 13.0) covers cu121/cu124 wheels.
    - sm_50 warning "GPU with CUDA capability 5.0 is not compatible"
      → expected on newest torch; use cu121 wheels or llama.cpp.

T7. Docker in CT can't see GPU:   [CT]
    - install nvidia-container-toolkit; if "BPF_CGROUP_DEVICE:
      operation not permitted", set `no-cgroups = true` in
      /etc/nvidia-container-runtime/config.toml (unprivileged CT).
    - env NVIDIA_VISIBLE_DEVICES + NVIDIA_DRIVER_CAPABILITIES must be
      set for the container runtime (they're in /etc/environment, but
      Docker needs them per-container or via nvidia runtime defaults).

==========================================================
Known constraints (GTX 950M / Maxwell)
==========================================================
- Driver locked to 580 branch forever (last Maxwell branch); CUDA 12.x max.
- NVENC: H.264 encode only, no HEVC. NVDEC fine for 1080p-class.
- sm_50: use llama.cpp for LLM (PyTorch/vLLM are dropping Maxwell).
- Unprivileged CT note: if device access is denied despite the config,
  either remap the device cgroup or make the CT privileged.
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

  echo "== PATCH REQUIRED ==" # (informational only — the vmflags patch above was already auto-applied if present)
  cat <<'NOTE'
Kernel 7.0 breaks the 580 build. nvidia-7.0-vmflags-580.159.03.patch
(from this repo) is the only required patch and was auto-applied above
if present. The other community patches (strlcpy, dma-fence, VMA) are
OBSOLETE for 580.159.03 — do not add them. See runbook DO-NOT-RUN #9.
NOTE
  read -rp "Continue with DKMS install? [y/N] " ok
  [ "$ok" = "y" ] || { echo "Aborting."; exit 1; }

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
  echo "== device nodes (note the nvidia-uvm major: 510 on this host, feeds CT cgroup rule) =="
  ls -l /dev/nvidia* 2>/dev/null || echo "no /dev/nvidia* — try: nvidia-modprobe -u -c 0; nvidia-smi"
  echo "== module loaded =="
  lsmod | grep nvidia
  echo
  echo "If all four passed: HOST SIDE COMPLETE."
  echo "Next: create/restore the CT (runbook PART 0 P0.5), then Part B (LXC config)."
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
# NVIDIA GPU passthrough — pve2 → hermesagent (LXC 100) — FINAL REPORT

## Hardware reality (from live system)
- Host: HP laptop, i7-6700HQ, PVE kernel 7.0.14-16-pve, Debian 13 base.
- GPU: **GTX 950M (GM107, Maxwell)**, compute capability 5.0, 2–4 GB VRAM, NVENC = H.264 only (no HEVC encode), NVDEC up to 1080p-class.
- iGPU: Intel HD 530 (host console — no passthrough needed for it).
- Guest: **LXC container 100 "hermesagent"** (not a VM).

## Decisive facts (sourced)
1. **Maxwell is driver-locked.** Driver branch 580 is the last to support Maxwell/Pascal/Volta
   (Phoronix 2025-07-01: https://www.phoronix.com/news/NVIDIA-580-Linux-Driver-Last-HW ;
   NVIDIA deprecation schedule via TechPowerUp/Tom's Hardware). CUDA 12.x is also the last for Maxwell.
   → The researched suggestion of 595/610 is **wrong for this card**; those branches dropped Maxwell.
2. **Kernel 7.0 breaks both 550 and unpatched 580 DKMS builds.** Field reports: 580.105.08 fails on
   7.0.x-pve (fiwares.com write-up; Proxmox forum threads); Debian 550.163.01 tops out ~6.18.
   Community C patches exist for 550.x/580.x on kernel 7.0+ (gist.github.com/louzt/1c85044d5090d19223c3f5edf426a19c):
   - VMA API change (nv-mm.h / nv-mmap.c)
   - nvidia-dma-fence-helper.h (second failure, all branches)
   - `__vm_flags` removal (kernels 7.0.2+ — ours is 7.0.14, so REQUIRED)
   - `strlcpy` removal (affects 580.x, not 550.x)
3. **LXC device sharing is the right architecture** for this box (research + consensus):
   - Host must load the NVIDIA kernel driver (so "host does zero GPU work" is unachievable literally,
     but with persistenced and no host GL/CUDA use, the card idles ~0%).
   - vs VFIO: no IOMMU/ACS/reset-bug exposure, iGPU console untouched, GPU shareable.
   - VFIO would also require converting hermesagent LXC→VM and gives the GPU to exactly one guest.

## Recommendation
LXC device sharing. Host driver = **580.x (proprietary, patched for kernel 7.0)** via `.run --dkms`
or patched Debian DKMS package; matching userspace inside the container.

Honest caveat: this card is a stopgap. Maxwell = sm_50 (modern inference stacks dropping it),
4 GB VRAM, H.264-only NVENC. For "max out on GPU LLM + transcoding," the real fix is newer hardware.

## Steps
### Host
1. Purge half-installed Debian NVIDIA stack:
   `apt remove --purge '^nvidia-.*' '^libnvidia-.*' -y && apt autoremove --purge -y`
2. `apt install -y build-essential dkms pve-headers`
3. Blacklist nouveau AND nova (`/etc/modprobe.d/blacklist-nvidia-nouveau.conf`):
   `blacklist nouveau` / `blacklist nova` / `options nouveau modeset=0`; `update-initramfs -u -k all`
4. Get NVIDIA-Linux-x86_64-580.xx.run (latest 580.159.03+ from download.nvidia.com/XFree86/Linux-x86_64/)
   + apply kernel-7.0 patches from the gist above (dkms.conf PATCH[] entries), then
   `./NVIDIA-Linux-x86_64-580.xx.run --dkms -s` (answer No to X config; headless).
   Fallback: keep running the older 6.17/6.18 PVE kernel where 580 DKMS builds cleanly.
5. Verify: `dkms status` (nvidia/580.x installed for 7.0.14-16-pve), `nvidia-smi`, `ls -l /dev/nvidia*`
6. `systemctl enable --now nvidia-persistenced`
   Optional: `/etc/modules-load.d/nvidia.conf` with nvidia, nvidia-uvm, nvidia-modeset

### Container (LXC 100)
7. `/etc/pve/lxc/100.conf` (stop CT first):
   ```
   lxc.cgroup2.devices.allow: c 195:* rwm
   lxc.cgroup2.devices.allow: c 511:* rwm
   lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
   lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
   lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
   lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
   ```
   (lxc.hook.mount nvidia hook is broken on PVE 9 — use manual entries)
8. Inside CT: install SAME driver version userspace:
   `.run --no-kernel-module`, or Debian nvidia packages matching 580.x
9. Docker inside CT (if used): nvidia-container-toolkit; on BPF_CGROUP_DEVICE error
   set `no-cgroups = true` in /etc/nvidia-container-runtime/config.toml
10. Env for both CUDA and NVENC: `NVIDIA_DRIVER_CAPABILITIES=compute,utility,video`
11. Verify: `nvidia-smi` in CT (version == host), then
    `ffmpeg -hwaccel cuda -i in.mp4 -c:v h264_nvenc out.mp4` and a CUDA smoke test
    (note: torch/pytorch builds for sm_50 are being dropped — use llama.cpp for LLM work)

## Maintenance
- Every PVE kernel upgrade: check `dkms status` rebuilds (pve-headers meta tracks this).
- Watch 580 legacy-branch releases for kernel 7.x fixes — it will receive occasional fixes, not features.
- Do NOT `apt full-upgrade` blindly: kernel 7.0 pulled in via metapackages is what wedged dpkg originally.--- a/common/inc/nv-mm.h
+++ b/common/inc/nv-mm.h
@@ -207,7 +207,11 @@ static inline void nv_vma_flags_set_word(struct vm_area_struct *vma, unsigned long flags)
 #if defined(NV_VMA_FLAGS_SET_WORD_PRESENT)
     vma_flags_set_word(&vma->flags, flags);
 #else
+#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 0, 0)
+    vm_flags_reset(vma, vma->vm_flags | flags);
+#else
     ACCESS_PRIVATE(vma, __vm_flags) |= flags;
+#endif
 #endif
 }
 
@@ -217,7 +221,11 @@ static inline void nv_vma_flags_clear_word(struct vm_area_struct *vma, unsigned long flags)
 #if defined(NV_VMA_FLAGS_SET_WORD_PRESENT)
     vma_flags_clear_word(&vma->flags, flags);
 #else
+#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 0, 0)
+    vm_flags_reset(vma, vma->vm_flags & ~flags);
+#else
     ACCESS_PRIVATE(vma, __vm_flags) &= ~flags;
+#endif
 #endif
 }
 

=== END OF REVIEW PACKAGE (40817 bytes total) ===
