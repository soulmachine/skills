# Reference — ESC8000 GPU-serving BIOS profile

Validated on ESC8000-E12P, 2× Xeon 6730P (Granite Rapids), 8× RTX PRO 6000 Blackwell, BIOS 0804,
registry `BiosAttributeRegistryS0317.8.4.0`. Applied + verified on two units (3ee, 3ed).

## The 10 tuned settings

| Setting | Attr | Default | Profile | Why (GPU serving) |
|---|---|---|---|---|
| Resize BAR Support | `PCIS034` | Disabled | **Enabled** | Full-VRAM BAR1; faster H2D/D2H on Blackwell |
| EPP profile | `CRB2MC` | Balanced Perf | **Performance** | Sustained serving clocks, no downclock |
| Energy-Perf Bias (EPB) | `CRB3JH` | Balanced Perf | **Performance** | Same, for EPB-consuming paths |
| Energy-Efficient Turbo | `CRB4EB` | Enable | **Disable** | No turbo sag under bursty inference |
| C1→C1E Promotion | `CRB3ID` | Enable | **Disable** | Removes p99 wake-latency jitter |
| Workload Configuration | `CRB5DU` | Balanced | **I/O sensitive** | GPU-DMA-heavy platform |
| Latency Optimized Mode | `AridLatencyOptimizedMode` | Disable | **Enabled** | GNR uncore low-latency mode |
| Sub-NUMA Clustering | `CRB3J4` | Auto | **Disable** | 1 NUMA node/socket — deterministic GPU↔mem affinity |
| ASPM Global (IIO) | `CRBAVX` | Per-Port | **Disable** | Kill PCIe link power-state transitions on GPU lanes |
| Restore on AC Power Loss | `AridApmLastState` | Last State | **Power On** | Always return after an outage |

Optional (not in profile): ACPI C6x `CRB0DE` → Disable, only for hard p99 SLOs (costs idle power).

## Baseline (verified, not changed) — VM-passthrough readiness

| Setting | Attr | Required | Note |
|---|---|---|---|
| Above 4G Decoding | `PCIS006` | Enabled | mandatory for many GPUs / large BARs |
| SR-IOV Support | `PCIS007` (+`CRBB4X`) | Enabled | needed for VF passthrough |
| PCIe ACS Control | `CRB04Y` | **Disabled** | fast GPU P2P for bare-metal serving; **flip to Enable only at VM adoption** (ACS isolation needed for safe passthrough) |
| VT-d (IOMMU) | *(no toggle)* | — | always exposed on Xeon 6; gate OS-side with `intel_iommu=on iommu=pt` |

If `tune_gpu_bios.py` finds a baseline attr differs, it folds it into the change set and prints a NOTE.

## Redfish API notes (AMI ASMB12)

- Attributes: `GET /redfish/v1/Systems/System_0/Bios` → `Attributes{}`. Members are `System_0`,
  `BMC_0` (not `…/Self`). Values are enum **tokens**, e.g. `PCIS034Enabled`, `CRB3J4Disable`.
- **Stage**: `PATCH /redfish/v1/Systems/System_0/Bios/SD` with `{"Attributes":{...}}` — use `/SD`,
  **not** `/Settings`. Requires `If-Match: <etag>` (GET `/Bios/SD` first) else **428**. Returns 204.
- **503** `Ami.1.0.ServiceTemporarilyUnavailableDueToHostBooting` while the host is mid-boot /
  BIOS-setup / inventory — staging is rejected; wait and retry (the script does, 45 s × 20).
- Staged settings are **pending** and reversible until reboot — PATCH the old values back to revert.
- **Apply** = reboot. This build has **no GracefulRestart** (allowed: ForceOff / ForceRestart /
  GracefulShutdown / On / PowerCycle — see `…/ResetActionInfo`). Use GracefulShutdown → poll
  `PowerState=Off` → On. POST + memory retrain after an SNC change ≈ 5–6 min.
- **Verify**: GET `/Bios` Attributes after POST. Mid-POST it reports `0/N` (old/empty map) — normal;
  flips to the new values once the host republishes its config.
- **Pacing**: single connection, small sleeps. A freshly-rebooted AMI BMC will lock out auth after a
  burst of requests (`Base.1.12.AccessDenied` on Redfish, `1012` on web, IPMI RMCP+ failures) — give
  it quiet time; don't hammer.

## Token drift across BIOS versions

Attribute keys and tokens are tied to the registry version. The stored `gpu_serving_profile.json`
is valid for BIOS 0804. For a different version, run with `--from-host <tuned_BMC>` so the script
reads the live token strings from a known-good server instead of the stored ones — the robust way
to clone one ESC8000's config onto another. Always confirm both run the same BIOS first
(`asus-esc8000-firmware-upgrade` skill).

## Outside BIOS (do separately)

- `intel_iommu=on iommu=pt` on the OS kernel cmdline (GRUB) for passthrough.
- Fan/thermal profile for sustained 8×600 W — BMC web UI, not BIOS.
- ACS flip (`CRB04Y`→Enable) + reboot when moving from bare-metal serving to VM passthrough.
