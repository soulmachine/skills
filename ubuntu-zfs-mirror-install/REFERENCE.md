# Reference — fixes, recovery, gotchas

Everything here is **already baked into the scripts**; this explains *why*, and how to recover if a
boot still misbehaves. These were learned the hard way during a real ESC8000-E12P install.

## What the scripts bake in (and why each matters)

| # | Fix (where) | Without it |
|---|---|---|
| 1 | **LVM/MD/swap teardown before wipe** — `swapoff`, `vgchange -an`, `mdadm --stop`, `dmsetup remove_all`, per-partition `wipefs` (install.sh / install-ext4.sh) | an old install on the target wedges `sgdisk` ("device in use", kernel won't re-read the table) |
| 2 | **`timeout` guards** on `partprobe` / `udevadm settle` | a busy device hangs partitioning indefinitely |
| 3 | **ZFS-in-initramfs HARD GATE** (`lsinitramfs \| grep zfs`, chroot-setup.sh) | a boot that can't import root, discovered only after reboot |
| 4 | **ZFSBootMenu on BOTH ESPs** + `efibootmgr -u "zbm.import_policy=force zbm.set_hostid=0"` | ZBM drops to its **emergency shell** "fs is undefined" (default `import_policy=hostid` won't claim an unclean/hostid-mismatched pool) |
| 5 | **`org.zfsbootmenu:commandline="quiet zfs_force=1"`** | OS initramfs does a *non-forcing* import → drops to `(initramfs)` "pool was previously in use from another system" after any hostid change |
| 6 | **udev-settle override → `/bin/true`** (chroot-setup.sh) | ZFS import units **hard-`Requires=systemd-udev-settle`**, which times out on big/many-device boxes → `dpool`/`/data` never auto-imports + "degraded" |
| 7 | **hostid**: `zgenhostid` + copy `/etc/hostid` to target | pools created under one hostid, OS boots under another (#4/#5/#6 make a mismatch non-fatal anyway) |

> Important: do **NOT** `udevadm control --stop-exec-queue` to stop udev re-activating LVM mid-wipe —
> it *hangs* `vgchange`/`dmsetup` (they wait on udev cookies). The teardown order in the scripts is enough.

## Recovery (if a boot still stops)

- **ZFSBootMenu emergency shell** (`zfsbootmenu />`): `zpool import -f -N rpool` → `exit`. (Permanent fix
  is the `import_policy=force` boot-entry option, already applied.)
- **OS `(initramfs)` "pool in use by another system"**: `zpool import -f -N rpool` → `exit` once. Permanent
  fix is `zfs_force=1` (already in `org.zfsbootmenu:commandline`); verify with `cat /proc/cmdline`.
- **`/data` missing after boot** (dpool not imported): check `systemctl status zfs-import-cache` and
  `zpool import` (look for "another system" → hostid). Mount now: `sudo zpool import -f dpool`. Permanent
  fix is the udev-settle override (#6) + matching hostid.
- **"degraded" system state**: usually the udev-settle unit; the override fixes it. `systemctl --failed` to see what.

## Single-disk failure (ZFS layout)

`rpool` mirror survives one disk loss → still boots (degraded) off the survivor's ESP/ZBM entry.
`dpool` is a **stripe → all `/data` is lost** if either disk dies (the deliberate capacity-over-redundancy trade).
Replace: re-partition the new disk identically → `zpool replace rpool <old> <new>-part2` → `mkfs.vfat` its ESP,
copy `\EFI\ZBM\VMLINUZ.EFI`, re-add its `efibootmgr` entry → recreate `dpool` and restore from backup.

## Adding kernel args later (ZFS path has no GRUB)

```bash
sudo zfs set org.zfsbootmenu:commandline="quiet zfs_force=1 intel_iommu=on iommu=pt" rpool/ROOT
```
Keep `zfs_force=1`. This property *is* the kernel command line; there is no `/etc/default/grub`.

## Hardware notes

- **ASUS ESC8000-E12P (AMI BMC)**: Redfish boot-override / BootOrder is **broken** on its firmware —
  the only reliable way to boot the installer USB is **F8** at POST (one-time boot menu). Its virtual-media
  (network ISO mount) is also broken; use a physical USB. Mac↔host-data-net routing via the BMC tunnel can be
  intermittent — retry SSH when it times out.
- **Disk naming**: scripts reference partitions by `/dev/disk/by-id/<id>-partN` (stable for NVMe *and* SATA);
  `efibootmgr` uses the whole-disk device. Always select disks by their **by-id** path.

## ext4 fallback (`install-ext4.sh`)

Plain single-disk install: `ESP(1G FAT32) | ext4 root(rest)`, **GRUB-EFI** (no ZFS → none of #3–#7 apply).
Used when there aren't two equal-size disks. A second disk (if present) is left untouched.
