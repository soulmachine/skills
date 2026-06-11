# LXD GPU Server — Reference

Companion to [SKILL.md](SKILL.md). The *why*, the alternatives, and the failure modes.

## 1. Scope & assumptions

This skill takes a host that **already has working GPUs** (driver loaded, `nvidia-smi -L` lists them, and
`nvidia-ctk` present from `nvidia-container-toolkit`) and:

- installs LXD (snap) + initialises it with one storage pool and a NAT bridge,
- generates a host CDI spec,
- attaches an all-GPU CDI device to the `default` profile so **every** container gets every GPU.

Host GPU enablement (driver, IOMMU, CUDA, container toolkit) is the **`ubuntu-nvidia-gpu-enablement`** skill —
run it first. This skill is about getting those GPUs *into LXD containers*.

LXD vs Incus: Ubuntu ships LXD as a snap (`lxc` CLI). The community fork **Incus** (deb, `incus` CLI) works the
same way — substitute `incus` for `lxc` and `incus admin init` for `lxd init`; CDI device syntax is identical.

## 2. Storage backends & the preseed

`lxd init` is fed a preseed (non-interactive). The install script builds the `storage_pools` block from
`LXD_STORAGE`:

| `LXD_STORAGE` | Result | When |
|---|---|---|
| `zfs:rpool/lxd` | LXD creates dataset `rpool/lxd` on an **existing** zpool | Host already on ZFS — best. Put it on a redundant (mirror) pool for resilience, or a big stripe for space. |
| `zfs-loop:50GiB` | LXD creates a loop-file-backed zpool | ZFS userspace present but no spare pool/disk. Fine for light use; loop file lives under `/var/snap/lxd`. |
| `dir` | Plain directory under `/var/snap/lxd/common/lxd/storage-pools` | No ZFS; any filesystem. Simplest, no snapshots/clones, slower copies. |
| `btrfs:/dev/sdX` | btrfs pool on a block device | btrfs hosts; gives CoW snapshots like ZFS. |

Full preseed the script emits (ZFS example):

```yaml
config: {}
networks:
- name: lxdbr0
  type: bridge
  config:
    ipv4.address: auto      # random private /24, NAT on; avoids LAN/Tailnet clashes
    ipv6.address: none
storage_pools:
- name: default
  driver: zfs
  config:
    source: rpool/lxd       # existing pool -> LXD creates this child dataset
profiles:
- name: default
  devices:
    eth0: {name: eth0, network: lxdbr0, type: nic}
    root: {path: /, pool: default, type: disk}
```

`lxc query /1.0` once initialised confirms `storage: zfs` and the driver versions. The pool's `source` **cannot
be changed in place** later — to relocate it you recreate the pool (§6).

## 3. Granting GPUs

**Device syntax** (the `gpu` device, CDI mode):

```bash
lxc <profile|config> device add <target> <devname> gpu gputype=physical id=<CDI-name>
```

`id` CDI names come from the spec (`nvidia-ctk cdi list`):

| `id` | Grants |
|---|---|
| `nvidia.com/gpu=all` | every discrete GPU |
| `nvidia.com/gpu=0` | one GPU by index |
| `nvidia.com/gpu=GPU-<uuid>` | one GPU by UUID (stable across reboots/reorders) |
| `nvidia.com/igpu=all` | integrated GPUs |

**All instances vs per-instance.** Put the device on the **`default` profile** → every container (current and
future) inherits all GPUs — the faithful reading of "all GPUs to all instances", and a single source of truth.
For selective access instead, leave the profile GPU-free and `lxc config device add <inst> …` per container
(optionally with a dedicated profile per GPU set).

**What CDI injects.** The generated spec mounts the driver user-space (libnvidia-*, **libcuda**, `nvidia-smi`)
read-only from the host and runs `nvidia-cdi-hook` to create symlinks + update the container's ld cache. So both
`nvidia-smi` *and* CUDA workloads (PyTorch/vLLM/TensorRT) work — no driver install inside the container, and the
container's user-space always matches the host kernel module (they must match exactly; CDI guarantees it).

`gputype` values: only **`physical`** supports CDI and works for containers. `mig` (containers), `mdev`/`sriov`
(VMs) are non-CDI vGPU paths — out of scope here.

## 4. CDI vs `nvidia.runtime` — why the legacy path is avoided

LXD has two ways to get GPUs into a container:

1. **`nvidia.runtime=true` (legacy).** At container start LXD runs a mount hook
   (`/snap/lxd/current/lxc/hooks/nvidia`) that calls the snap's **bundled** `libnvidia-container`
   (`nvidia-container-cli configure`) to inject the driver from `/var/lib/snapd/hostfs`. The CLI spawns a
   "driver" subprocess that talks NVML over RPC. On recent kernels (observed: **kernel 7.0 + Blackwell + snap LXD
   5.21**) that RPC **hangs ~13s and fails**:
   ```
   nvidia-container-cli.real: initialization error: driver rpc error: timed out
   ```
   The bundled CLI can *enumerate* GPUs fine (`nvidia-container-cli info` works); it's the configure/driver-RPC
   step inside the LXC mount-hook namespace that times out. Independent of `nvidia.driver.capabilities`.

2. **CDI (recommended).** `nvidia-ctk cdi generate` (the **host** toolkit, e.g. 1.19.x — newer than the snap's
   bundled one) writes a *static* spec of mounts + hooks. LXD applies it as ordinary bind-mounts/device nodes —
   **no `libnvidia-container` runtime, no driver RPC, no hostfs dependency, no timeout.** It also uses your
   up-to-date host toolkit, so new architectures are supported as soon as the host toolkit is.

Do **not** combine them. If a profile/instance has stale `nvidia.runtime`/`nvidia.driver.capabilities` config,
remove it (`lxc profile unset default nvidia.runtime`); the install script does this automatically.

**Diagnosing a failed start** (any cause):
```bash
sudo /snap/bin/lxc info --show-log <name> | grep -iE 'nvidia|hook|driver rpc|error'   # hook stderr
sudo /snap/bin/lxc config set <name> raw.lxc 'lxc.log.level=debug'                     # force verbose hook log
```

## 5. Maintenance — keep the CDI spec fresh

The spec at `/etc/cdi/nvidia.yaml` pins exact versioned library paths (e.g. `libnvidia-ml.so.<driver-ver>`).
After a host driver upgrade those paths change and containers fail with missing-library / NVML version-mismatch
errors until the spec is regenerated. Two ways to keep it fresh — `install-lxd.sh` picks automatically:

**Modern toolkit (`nvidia-container-toolkit` ≥ 1.17) — use its own units (preferred).** The package ships
`nvidia-cdi-refresh.service` plus a `nvidia-cdi-refresh.path` that watches `/usr/bin/nvidia-ctk` and
`/lib/modules/$(uname -r)/modules.dep[.bin]`, so the spec regenerates on **every driver/toolkit install or
upgrade** (event-driven, before you even reboot) **and** at boot (the service is `WantedBy=multi-user.target`).
This is strictly better than a hand-rolled boot unit — don't add one. **One catch:** the service writes to the
**tmpfs `/var/run/cdi/nvidia.yaml`** by default, while this skill uses the persistent `/etc/cdi/nvidia.yaml`. Pin
it via the toolkit's own override file so there's a single, persistent source of truth:

```bash
echo 'NVIDIA_CTK_CDI_OUTPUT_FILE_PATH=/etc/cdi/nvidia.yaml' | sudo tee -a /etc/nvidia-container-toolkit/nvidia-cdi-refresh.env
sudo systemctl enable --now nvidia-cdi-refresh.path
sudo systemctl start nvidia-cdi-refresh.service           # regenerate now -> /etc/cdi
sudo rm -f /var/run/cdi/nvidia.yaml                       # remove the old tmpfs copy (see warning)
```

⚠️ **Never leave a spec in both `/etc/cdi` and `/var/run/cdi`.** LXD (CDI) scans *both* directories; after a
driver upgrade one is fresh and the other stale, and both define `nvidia.com/gpu=*`, so the CDI library hits
**duplicate / conflicting device names** and GPU passthrough breaks. Pin to one location and delete the other.
Persistent `/etc/cdi` is preferred for LXD: it survives reboot, so there's no tmpfs regeneration race before
autostart GPU containers come up.

**Older toolkit (no `nvidia-cdi-refresh` units) — install a boot unit.** The script writes this fallback. Note
the **distinct name** — so a future toolkit upgrade that ships `nvidia-cdi-refresh.*` can't collide with it:

```ini
# /etc/systemd/system/lxd-nvidia-cdi-refresh.service
[Unit]
Description=Regenerate NVIDIA CDI spec for LXD (fallback; toolkit ships no nvidia-cdi-refresh units)
After=local-fs.target
Before=snap.lxd.daemon.service

[Service]
Type=oneshot
ExecStartPre=/usr/bin/mkdir -p /etc/cdi
ExecStart=/usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl enable lxd-nvidia-cdi-refresh.service
```
Alternative: an APT hook (`/etc/apt/apt.conf.d/99-nvidia-cdi`) running the same command `DPkg::Post-Invoke`.
Either way, re-run is safe and idempotent.

## 6. Moving the storage pool between ZFS pools

LXD can't re-`source` a pool in place. To move `default` from one ZFS pool to another (e.g. `dpool/lxd` →
`rpool/lxd`), recreate it. **Destroys instances on that pool** — back up / `lxc export` anything real first.
Trivial when empty:

```bash
# stop & remove everything on the pool
for c in $(sudo /snap/bin/lxc list -c n -f csv); do sudo /snap/bin/lxc delete -f "$c"; done
for i in $(sudo /snap/bin/lxc image list --format csv -c f); do sudo /snap/bin/lxc image delete "$i"; done
sudo /snap/bin/lxc profile device remove default root          # release the pool from the profile
sudo /snap/bin/lxc storage delete default                     # destroys the old ZFS dataset
sudo /snap/bin/lxc storage create default zfs source=rpool/lxd
sudo /snap/bin/lxc profile device add default root disk pool=default path=/
```
The GPU device on the profile is independent of storage, so passthrough is unaffected. To **keep** instances,
add the new pool under a second name and `lxc move <inst> --storage <newpool>` instead (you then live with the
new pool name, since pools can't be renamed).

## 7. Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `driver rpc error: timed out` at start | Legacy `nvidia.runtime` path. Remove it; use CDI (§4). |
| `Error: Failed to run: … forkstart … exit status 1` | A mount hook failed — check `lxc info --show-log` (§4). |
| `sudo: lxc: command not found` | `secure_path` lacks `/snap/bin`. Call `sudo /snap/bin/lxc`. |
| `lxc` needs sudo even after `usermod -aG lxd` | Group membership needs a fresh login/session. |
| Container start OK but `nvidia-smi: command not found` inside | CDI spec missing/stale, or device not attached. `nvidia-ctk cdi list`; regenerate (§5); check `lxc config device show <inst>`. |
| `Failed to initialize NVML: Driver/library version mismatch` | Host driver upgraded, spec stale → regenerate the CDI spec (§5). |
| Containers see 0 GPUs after reboot/upgrade | Stale spec — regenerate, and make sure auto-refresh is wired (§5). |
| Passthrough breaks after a driver upgrade; duplicate / conflicting CDI device error | A spec exists in **both** `/etc/cdi` and `/var/run/cdi` and they diverged. Keep one location, delete the other, pin the refresh service to it (§5). |
| `lxd init` fails: source dataset busy/exists | Pick an unused dataset name (`zfs:<pool>/lxd`), or `dir`. |
| Bridge subnet clashes with LAN/VPN | `lxc network set lxdbr0 ipv4.address 10.x.y.1/24` (and re-NAT). |

## 8. Uninstall

```bash
sudo /snap/bin/lxc list -c n -f csv | xargs -r -n1 sudo /snap/bin/lxc delete -f
sudo snap remove lxd            # add --purge to drop all data
# ZFS-backed pool dataset (if any) is removed with the snap data; verify: zfs list | grep lxd
sudo rm -f /etc/cdi/nvidia.yaml /etc/systemd/system/lxd-nvidia-cdi-refresh.service   # our fallback unit, if installed
# if you pinned the packaged refresh service to /etc/cdi (§5), undo it (leave the packaged
# nvidia-cdi-refresh.{service,path} alone — they belong to nvidia-container-toolkit):
sudo sed -i '/^NVIDIA_CTK_CDI_OUTPUT_FILE_PATH=/d' /etc/nvidia-container-toolkit/nvidia-cdi-refresh.env 2>/dev/null || true
```
