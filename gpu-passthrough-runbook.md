# pve2 NVIDIA → hermesagent LXC: step-by-step runbook

Two artifacts:
- pve2-host-nvidia-setup.sh  → all HOST steps, phases 0-3
- this file                  → full ordered checklist with the LXC part

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
    NOTE the major numbers (normally 195 for nvidia*, 511 for nvidia-uvm):
    they feed the cgroup rules in B1.

==========================================================
PART B — LXC hermesagent (VMID 100) — ONLY AFTER PART A PASSES
==========================================================

B1. Stop the container:
    pct stop 100

B2. Add to /etc/pve/lxc/100.conf  (use the major numbers from A3):
    lxc.cgroup2.devices.allow: c 195:* rwm
    lxc.cgroup2.devices.allow: c 511:* rwm
    lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
    lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
    lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
    lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file

B3. Start container:
    pct start 100

B4. Inside the container — install MATCHING userspace (580.159.03, no kernel module):
    EITHER:  bash NVIDIA-Linux-x86_64-580.159.03.run --no-kernel-module -s
    OR:      copy host libs manually (libcuda, libnvidia-ml, nvidia-smi)
    Version must EXACTLY match host (check: nvidia-smi | head -1 in both).

B5. Environment for CUDA + NVENC (in shell profile, systemd units, or Docker env):
    NVIDIA_VISIBLE_DEVICES=all
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

B6. Docker inside the CT (only if you use Docker):
    install nvidia-container-toolkit per NVIDIA docs
    if "BPF_CGROUP_DEVICE: operation not permitted":
      set no-cgroups = true in /etc/nvidia-container-runtime/config.toml

B7. Verification inside container:
    nvidia-smi                      # driver 580.159.03, GTX 950M
    ffmpeg -hwaccel cuda -i test.mp4 -c:v h264_nvenc out.mp4   # NVENC (H.264 only)
    python: llama.cpp / CUDA smoke test                        # CUDA (sm_50)

B8. Full reboot test (host + CT) to confirm persistence across reboots.

==========================================================
Known constraints (GTX 950M / Maxwell)
==========================================================
- Driver locked to 580 branch forever (last Maxwell branch); CUDA 12.x max.
- NVENC: H.264 encode only, no HEVC. NVDEC fine for 1080p-class.
- sm_50: use llama.cpp for LLM (PyTorch/vLLM are dropping Maxwell).
- Unprivileged CT note: if device access is denied despite the config,
  either remap the device cgroup or make the CT privileged.
