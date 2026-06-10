# Reference — Ubuntu NVIDIA GPU Enablement

Detail, rationale, and troubleshooting behind [SKILL.md](SKILL.md).

## 1. Driver selection

**Open vs proprietary kernel modules**
- **Blackwell (GB2xx) requires the open kernel modules** — the proprietary modules don't support it.
  Hopper / Grace-Hopper also require open. Turing→Ada work with either; open is NVIDIA's default going forward.
- Package naming: `nvidia-driver-<ver>-open` (general/feature branch) and
  `nvidia-driver-<ver>-server-open` (datacenter/LTS branch) — both build the open modules.
- For datacenter / "Server Edition" cards on a headless host, prefer **`-server-open`** (datacenter QA,
  longer support cadence). `-open` works too and may carry slightly newer userspace.

**Picking a version**
- `ubuntu-drivers devices` prints the recommended package for your exact PCI IDs.
- Newest drivers come from NVIDIA's CUDA apt repo
  (`developer.download.nvidia.com/compute/cuda/repos/<distro>/x86_64`).
- A production/LTS branch is the safe default for a serving box; feature branches track the newest CUDA but
  churn more.

**Secure Boot / DKMS**
- Open modules build via DKMS against the running kernel — `linux-headers-$(uname -r)` must be installable.
- If Secure Boot is **on**, the freshly built modules are unsigned and won't load: enroll a MOK
  (`mokutil --import`, reboot, confirm at the console) or disable SB. A custom EFI bootloader (e.g.
  ZFSBootMenu) generally implies SB is already off — confirm via `mokutil --sb-state` or the `SecureBoot`
  efivar.

**Activation** — installing the driver blacklists nouveau, but nouveau stays loaded until reboot. After
reboot: `cat /proc/driver/nvidia/version` says "Open Kernel Module"; `lsmod | grep nouveau` is empty;
`nvidia-smi` enumerates every GPU.

## 2. IOMMU

**Why `iommu=pt`** — passthrough/identity-mapped DMA: near-native bandwidth on bare metal, and it keeps
NVIDIA P2P enabled. Plain `intel_iommu=on` (full translation) can make the driver disable PCIe P2P, so
NCCL/collectives fall back to staging through host shared memory. Always use `iommu=pt` on a serving box.

**Intel vs AMD** — Intel: `intel_iommu=on iommu=pt`. AMD: `amd_iommu=on iommu=pt`.

**Where the cmdline lives**
- **GRUB:** `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then `sudo update-grub`.
- **ZFSBootMenu:** the ZFS property `org.zfsbootmenu:commandline` on the boot ROOT dataset (e.g.
  `rpool/ROOT`); boot environments inherit it. **Always read-then-append** so you preserve tokens like
  `zfs_force=1` (force-import) and `quiet`. A malformed value can drop you to a ZBM/initramfs shell, so keep
  console access and verify the readback before rebooting.

**IOMMU groups & ACS**
- Each isolated PCIe function gets an IOMMU group. With **ACS disabled**, devices behind a shared switch may
  share a group; if the topology already puts each GPU on its own root port, every GPU can still land in its
  own group even with ACS off (best case — per-GPU VFIO-passthrough-ready without flipping ACS).
- For per-GPU VFIO passthrough each GPU must be in its own group; turn ACS **on** in BIOS only then (ACS on
  adds a small P2P cost, so leave it off for bare-metal serving).
- Inspect: `ls /sys/kernel/iommu_groups | wc -l`, and per GPU:
  `basename "$(readlink /sys/bus/pci/devices/<addr>/iommu_group)"`.

## 3. CUDA toolkit

**PATH** — Ubuntu's `cuda-toolkit` sets the `/usr/local/cuda` → `cuda-<ver>` symlink and an `ld.so.conf.d`
entry for the runtime libs, but does **not** add `/usr/local/cuda/bin` to PATH. Drop
`/etc/profile.d/cuda.sh` with `CUDA_HOME` + `PATH` (login shells; non-login shells must source it).

**Toolkit/driver minor skew** — a toolkit minor newer than the driver's reported CUDA (e.g. toolkit 13.1,
driver "CUDA 13.0") is fine: CUDA minor-version compatibility lets 13.x apps run on a 13.(x-1) driver.

**glibc compile clash (bleeding-edge distros)** — glibc ≥ 2.41 (Ubuntu 26.04 ships 2.43) added `rsqrt`/
`rsqrtf`, which collide with the same declarations in older CUDA headers (`crt/math_functions.h` vs
`bits/mathcalls.h`) → `error: exception specification is incompatible with that of previous function`. The
error is raised by nvcc's **EDG frontend**, so `-ccbin <other gcc>`, `-Xcompiler -fpermissive`,
`-std=c++17`, and feature-macro defines all **fail**. Impact: **running prebuilt frameworks is unaffected**
(they use the driver + libcudart and never call nvcc); only **compiling CUDA C++/extensions from source
on-box** breaks. Options:
1. Guard-patch the two header lines: wrap the `rsqrt`/`rsqrtf` decls in
   `#if !__GLIBC_PREREQ(2,41) ... #endif` (reversible; reverts on toolkit upgrade; verify device math still
   builds afterward).
2. Compile inside an NVIDIA CUDA container (bundles a matching glibc).
3. Move to a CUDA release that supports the newer glibc.

## 4. nvidia-persistenced

**Boot-enable** — Ubuntu ships the unit `static` (no `[Install]` section), so `systemctl enable` creates no
boot symlink. Add a drop-in, then re-enable:
```
# /etc/systemd/system/nvidia-persistenced.service.d/install.conf
[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nvidia-persistenced   # is-enabled -> "enabled"
```

**"Persistence-M: Disabled" is expected** — that nvidia-smi column reflects the *deprecated legacy*
persistence-mode flag, which the daemon deliberately does not set. Persistence comes from the daemon holding
`/dev/nvidiactl` open and registering each GPU. Confirm it's working:
```bash
journalctl -u nvidia-persistenced | grep registered   # "device <addr> - registered" per GPU
```
Don't add `nvidia-smi -pm 1` — deprecated, and it doesn't survive reboot anyway.

## 5. Container access

### Container engine (Docker) — install it first
The toolkit only *wires* an existing engine, so a runtime must already be present. Docker's official
`docker-ce` apt repo trails new Ubuntu releases by months; on a brand-new release `dists/<codename>/` 404s.
Check before adding it:
```bash
curl -fsI "https://download.docker.com/linux/ubuntu/dists/$(. /etc/os-release; echo $VERSION_CODENAME)/Release" -o /dev/null -w '%{http_code}\n'
```
- **200** → add the `docker-ce` repo the usual way.
- **404 / 000** (e.g. 26.04 `resolute`) → install Ubuntu's own **`docker.io`** — it's current (26.04 ships
  Docker 29.x) and fully compatible with the nvidia runtime: `sudo apt-get install -y docker.io`.

Add your user to the `docker` group for the rootless CLI (`sudo usermod -aG docker "$USER"`; re-login to
apply). Docker coexists with Tailscale: it manages its own `iptables-nft` chains + `docker0` bridge.

### NVIDIA repo + toolkit
Add the repo once (distro-agnostic — works even on very new Ubuntu):
```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
```
- **Full toolkit:** `apt-get install -y nvidia-container-toolkit` → `nvidia-ctk` + an auto-generated CDI
  spec (`nvidia-ctk cdi list` → `nvidia.com/gpu=0..N` *plus* per-UUID entries + `=all`, i.e. 2N+1 devices).
  Wire a runtime: `sudo nvidia-ctk runtime configure --runtime=docker|containerd` then
  `sudo systemctl restart docker`. That writes only a `runtimes.nvidia` block to `/etc/docker/daemon.json`
  (path `nvidia-container-runtime`) and **leaves the default runtime `runc`** — correct; opt in per container
  with `--gpus`/`--runtime=nvidia`. Podman uses CDI directly (`--device nvidia.com/gpu=all`).
- **Minimal:** `apt-get install -y libnvidia-container-tools` → just `nvidia-container-cli`
  (`nvidia-container-cli info` lists GPUs). Pulls `libnvidia-container1`.
- **Pare full → minimal:** `apt-mark manual libnvidia-container-tools libnvidia-container1`, then
  `apt-get purge nvidia-container-toolkit nvidia-container-toolkit-base` (autoremove keeps the libs; a stale
  `/run/cdi/nvidia.yaml` can be removed).

### Verify + the driver-capabilities gotcha
```bash
sudo docker run --rm --gpus all -e NVIDIA_DRIVER_CAPABILITIES=all ubuntu:24.04 nvidia-smi -L   # lists every GPU
```
`--gpus all` *selects* the devices, but **`NVIDIA_DRIVER_CAPABILITIES` decides which userspace gets injected**:
no `utility` → no `nvidia-smi` (you'll see "executable file not found in $PATH"); no `compute` → no CUDA libs.
Set `-e NVIDIA_DRIVER_CAPABILITIES=all` (or `compute,utility`), or use an `nvidia/cuda` image that sets it.
A bare `docker run --gpus all ubuntu nvidia-smi` with no caps is the usual "it doesn't work" trap.

## 6. BIOS — GPU serving profile (generic)

| Setting | Target | Why |
|---|---|---|
| Above 4G Decoding | Enabled | Map full GPU BAR space |
| Resize BAR | Enabled | Full-VRAM BAR1; faster H2D/D2H |
| Power / EPP profile | Performance | Sustained clocks under serving load |
| Energy-Efficient Turbo | Disabled | No turbo sag on bursty utilization |
| C-state / C1E promotion | Disabled | Lower p99 wake-latency jitter |
| ASPM (PCIe/IIO) | Disabled | Kill PCIe link power-state transitions |
| SR-IOV | Enabled | Needed for VM / SR-IOV passthrough |
| VT-d / IOMMU | Enabled / available | Pairs with the kernel cmdline (Step 2) |
| PCIe ACS | Off for bare-metal P2P | Flip On only to isolate GPUs for VFIO |
| Sub-NUMA Clustering | Disabled | Deterministic 1 NUMA node/socket for GPU affinity |

For **ASUS ESC8000-E12P** exact Redfish attribute tokens (e.g. `PCIS034`=ReBAR, `CRB2MC`=EPP,
`CRB3J4`=SNC, `CRBAVX`=ASPM-IIO, `CRB04Y`=ACS) and a diff/stage/reboot/verify workflow, use the
`asus-esc8000-gpu-bios-tuning` skill. NVLink/NVSwitch systems also need `nvidia-fabricmanager`; PCIe-only
P2P boards don't.

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `nvidia-smi`: "couldn't communicate with the NVIDIA driver" | Driver installed but not active — reboot to unload nouveau and load nvidia. |
| nouveau still loaded after install | Reboot; if it persists, confirm the blacklist (`/etc/modprobe.d/*nvidia*`) and rebuild initramfs. |
| DKMS module build fails | Missing `linux-headers-$(uname -r)`; or Secure Boot on (enroll MOK / disable SB); or host gcc/glibc newer than the driver supports. |
| `/proc/cmdline` lacks IOMMU flags | GRUB: forgot `update-grub`. ZBM: edited the wrong dataset, or set vs inherited — set on the ROOT dataset, reboot. |
| No IOMMU groups / `dmesg` shows no DMAR | VT-d/IOMMU disabled in BIOS, or the cmdline wasn't applied. |
| `nvidia-smi topo -p2p` shows NS/CNS | Likely full translation — ensure `iommu=pt` is on; check BIOS PCIe ACS / topology. |
| Boot drops to initramfs (ZFS root) | A cmdline edit dropped `zfs_force=1`/`quiet` — restore the full property; recover in-shell: `zpool import -f -N rpool; exit`. |
| `nvcc: command not found` | Not on PATH — add `/etc/profile.d/cuda.sh`; use a login shell. |
| nvcc "exception specification is incompatible" | glibc-vs-CUDA header clash — §3. Serving is unaffected. |
| Persistence-M shows Disabled | Expected with the daemon — §4. Not a bug. |
| `docker-ce` apt add fails / no `Release` for the codename on a new Ubuntu | Official Docker repo lags releases — install Ubuntu's `docker.io` instead (§5). |
| Container: `nvidia-smi`/CUDA libs absent, or "executable file not found" with `--gpus all` | Driver capabilities not set — add `-e NVIDIA_DRIVER_CAPABILITIES=all` (utility=nvidia-smi, compute=CUDA), or use an `nvidia/cuda` image (§5). |

## 8. Verify reference

```bash
nvidia-smi --query-gpu=index,name,driver_version,memory.total,ecc.mode.current --format=csv
cat /proc/driver/nvidia/version                       # Open Kernel Module
cat /proc/cmdline                                     # iommu flags + preserved tokens
sudo dmesg | grep -iE 'DMAR:|IOMMU enabled'
ls /sys/kernel/iommu_groups | wc -l                   # > 0
nvidia-smi topo -m                                    # NUMA / PCIe layout, NIC affinity
nvidia-smi topo -p2p r                                # P2P "OK" across GPUs
systemctl is-enabled nvidia-persistenced              # enabled
journalctl -u nvidia-persistenced | grep registered   # daemon holds each GPU
bash -lc 'nvcc --version'
```
