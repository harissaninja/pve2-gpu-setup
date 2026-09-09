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
