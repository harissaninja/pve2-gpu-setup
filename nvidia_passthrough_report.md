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
- Do NOT `apt full-upgrade` blindly: kernel 7.0 pulled in via metapackages is what wedged dpkg originally.