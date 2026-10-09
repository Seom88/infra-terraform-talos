# 4. Single Control-Plane for 32 GiB Homelab (current 1×6 + 3×6)

* **Status:** Accepted (amended 2026-09-06; updated 2026-09-14 and 2026-09-29 — see the dated updates below)
* **Date:** 2026-09-06
* **Updated:** 2026-09-29 — worker vCPU `4` → `6` and worker CPU pinning disabled (CHANGELOG 2.3.0)
* **Deciders:** Seom88
* **Tags:** talos, proxmox, etcd, topology, homelab, cost

## Context

Substrate topology decision (Proxmox VM sizing, Talos `controlplane` vs `worker`, etcd quorum, Longhorn placement). Lives here, not in the GitOps repo — that repo owns platform (ArgoCD, Vault, SeaweedFS, monitoring); this repo owns the VMs hosting it. See [Decisions](./../decisions.md) and [Architecture](./../architecture.md).

### The 32 GiB hard ceiling

`pve01` is a single-node Proxmox VE host:

* **Host:** Intel i7-8700T (6c/12t), **32 GiB physical, 30.97 GiB usable**. No second node.
* **Overhead:** Proxmox itself ~2 GiB + TrueNAS VM **4 GiB / 2 cores** (lowered from 6 GiB 2026-09-14, ZFS-backed).
* **Old shape `3×6` CPs:** only **~1.4 GiB AVAILABLE** per node after kube/system-reserved. `kube-apiserver` alone (1.3–1.8 GiB peak) consumed >50%. Two of three etcd members flipped to `Fail` (slow `fdatasync` 1.5–2.0s vs 500ms threshold — memory pressure + `virtio0` without write-back cache).
* **Corrected 2026-09-06:** CP at **4 GiB** stays at **~40%** (`1472Mi / 3291Mi` allocatable, no `MemoryPressure`) when `allow_scheduling=false` and no Longhorn data disk. The 1.8 GiB apiserver peak was overestimated for current load.

### The wishlist that does not fit on 3×6

Estimated requests: Technitium 0.3 + Homepage 0.2 + CNPG/Postgres 1.0 + Nextcloud 1.5 + Immich 1.5 = **~4–5 GiB**. Old `3×6` gave `3 × 1.4 ≈ 4.2 GiB` total allocatable — already saturated by Cilium + Longhorn + kube-system.

### Why the obvious fixes do not work on 32 GiB

* **Upsize to `3×8`:** `3×8 + 4 + 2 ≈ 95%+` host → OOM/ballooning. Rejected (breaks 80% safety rule).
* **Rightsize `3×6` (tune requests, apiserver inflight, Longhorn replicas=2):** recovers only ~0.5–0.8 GiB/node. Delays OOM by one workload. Deferred as tuning, not topology fix.
* **Externalize TrueNAS:** frees 4–6 GiB but hardware does not exist. Deferred.
* **64 GiB upgrade:** correct long-term fix, blocked on budget.

### Verified post-GitOps (2026-09-06, 96 pods Running, 32m uptime)

* Nodes: `talos-cp1` (4c/4GB at the time) + `talos-w1..w3` (4c/6GB each), all `Ready`, `MemoryPressure: False`.
* Allocated: cp1 12% cpu / 45% mem; workers 44–51% cpu req (144–170% lim, overcommitted) / 30–37% mem req (79–88% lim).
* Biggest consumers: monitoring 1118Mi + longhorn-system 768Mi, not SeaweedFS (320Mi).
* Host math then: `4 + 18 + 6 (TrueNAS) + 2 (host) = 30 GiB → 96%`. Current (2026-09-14, TrueNAS 4 GiB + CP 6 GiB): `6 + 18 + 4 + 2 = 30 GiB → ~96%`. Exceeds 80% rule — accepted short-term (Proxmox has no ZFS ARC contention; ZFS lives inside TrueNAS VM only).

Purpose: **learning homelab, not enterprise prod**. Trading etcd HA for schedulable capacity is explicit and reversible.

## Decision

Run **single control-plane + three workers**: current deployed shape **`1×6 + 3×6`** per `terraform.tfvars` (history: original proposal `1×6 + 3×4` → amended `1×4 + 3×6` on 2026-09-06 → CP back to 6 GiB + TrueNAS lowered to 4 GiB on 2026-09-14).

| Role | Hostname | IP | Cores | Memory | Disk 0 | Disk 1 (data) | `allow_scheduling` |
|------|----------|----|-------|--------|--------|---------------|--------------------|
| control-plane | `talos-cp1` | `10.10.0.11` | 4 | `6×1024` | `40 GiB local-lvm` | none (EPHEMERAL only) | `false` |
| worker | `talos-w1` | `10.10.0.101` | 6 | `6×1024` | `40 GiB local-lvm` | `150 GiB ssd01` | `true` |
| worker | `talos-w2` | `10.10.0.102` | 6 | `6×1024` | `40 GiB local-lvm` | `150 GiB ssd01` | `true` |
| worker | `talos-w3` | `10.10.0.103` | 6 | `6×1024` | `40 GiB local-lvm` | `150 GiB ssd01` | `true` |

All on `pve01`. OS disks on `local-lvm` (SCSI `scsi0`, `virtio-scsi-single`), data disks on `ssd01`. Every VM also gets a dedicated **5 GiB swap backing disk** in `local-lvm` (CHANGELOG 2.3.0) behind a fixed 4 GiB `SwapVolumeConfig` — see [Architecture: Memory / swap design](./../architecture.md#memory--swap-design). CPU: the control-plane pin (`cpu_units = 200`, `cpu_affinity = "2-5,8-11"`) stays active, while worker `cpu_units`/`cpu_affinity` are commented out in `tfvars` since 2026-09-29 — `just affinity-sync` emits no worker rows and workers float until contention says otherwise. vCPU assigned: 18 Talos (CP 4 + 3×6) + 2 TrueNAS = 20 on 6c/12t.

* **CP:** Talos `controlplane` role, `NoSchedule` taint, no `UserVolumeConfig`, no Longhorn replicas (`Schedulable=false`). `longhorn-manager` DaemonSet still runs for CSI hooks.
* **Workers:** `worker` role, each with `150 GiB` data disk on `ssd01` → `UserVolumeConfig "data"` (`/var/mnt/data`). Longhorn replicas constrained to workers. 6 GiB = 5.48 GiB allocatable vs 3.29 GiB on 4 GiB.
* **Terraform:** `environments/proxmox/prod/terraform.tfvars` — `nodes_cp` (single entry, `cores = 4`, `memory = 6*1024`, `datastore = "local-lvm"`, `cpu_units = 200`, `cpu_affinity = "2-5,8-11"`, no data disk) + `nodes_worker` (three entries, `cores = 6`, `memory = 6*1024`, `datastore = "local-lvm"`, `cpu_units`/`cpu_affinity` commented out since 2026-09-29, `disks = [{ name = "data", size = 150, datastore = "ssd01" }]`). `modules/talos-cluster` maps `allow_scheduling` to `kubernetesAllowSchedulingOnControlPlanes` + taint; `modules/proxmox` adds the 5 GiB swap backing disk after the data disks.
* **Behavior:** `talos_cluster_health` targets only `10.10.0.11`. KubePrism `localhost:7445` fronts single apiserver, no VIP failover needed.
* **Revert:** `tfvars`-only. Re-add `talos-cp2/cp3` + `talosctl etcd join`, no worker state surgery, no Cilium/Longhorn reinstall.

### Update 2026-09-29 — worker vCPU 4→6, worker pinning disabled, swap backing (CHANGELOG 2.3.0)

* **Workers `cores` `4` → `6`** in `terraform.tfvars`: allocatable headroom back for the wishlist after the swap disk cost nothing extra (swap is a fixed-size block device, not RAM).
* **Worker CPU pinning disabled:** `cpu_units = 100` and `cpu_affinity = "2-5,8-11"` are commented out for all three workers, so `just affinity-sync` emits no prod worker rows and `cpu_units` falls back to the Proxmox default. Only the control-plane pin (`cpu_units = 200`, `cpu_affinity = "2-5,8-11"`) remains truthful config.
* **Swap:** every VM gained a dedicated 5 GiB `local-lvm` backing disk behind a fixed 4 GiB `SwapVolumeConfig` (`KubeletConfig` `LimitedSwap`, zswap 20%) — see [Architecture](./../architecture.md) and the swap verification runbook in [Operations](./../operations.md).

### Amendment 2026-09-06 — why deployed differed from original

Original `1×6 + 3×4` assumed TrueNAS 4 GiB and CP needing 6 GiB (~70% host). Live data: CP at 4 GiB was enough (40%), TrueNAS was actually 6 GiB, 4 GiB workers sat at 99% limits. The 2 GiB reclaimed from CP was reinvested into workers (4→6 GiB: limits 99% → 79–88%). Cost: host 70% → 90–96%.

### Update 2026-09-14 — aligned to `terraform.tfvars` (CP 6 GiB, TrueNAS 4 GiB, 150 GiB data)

* **CP back to 6 GiB:** `tfvars` sets `memory = 6*1024`, live CP 71% (3747Mi). The 4 GiB right-size proved too tight under full GitOps load — CP drift closed by adopting 6 GiB in this ADR. New tested minimum **4c + 5 GiB per node** still holds; CP at 6 GiB complies with margin.
* **TrueNAS lowered 6→4 GiB done:** now **2 cores / 4 GiB**. Host total unchanged (`6+18+4+2 = 30 GiB → ~96%`) — the 2 GiB freed from TrueNAS funds the 2 GiB returned to CP. Next relief valve is now workers 6→5 GiB (`6+15+4+2=27 GiB → 87%`) instead of TrueNAS.
* **Data disks 100→150 GiB** on `ssd01` (OS stays on `local-lvm`). Reflects current `tfvars` `disks` block.
* **CPU:** workers live `6→4` vCPU reconciled (16 vCPU Talos + 2 TrueNAS = 18 on 6c/12t); `cpu_units` CP `200` vs workers `100` in config; `cpu_affinity = "2-5,8-11"` is desired state in `tfvars` for all four Talos VMs (host/TrueNAS on 0-1), pending privileged `just affinity-sync` — API tokens cannot apply it, so CI ignores the attribute. Relative weight only, no pinning beyond the affinity string; validate via `turbostat` PkgWatt/%pc10 + guest steal%.
* Sizing still provisional: only ~19.6h Prometheus history (rebuilt 2026-09-13). Reconfirm after one week.

## Consequences

### Positive

* `3×6` workers ≈ 15 GiB effective allocatable vs ~7.5–9 GiB on `3×4` — fits 4–5 GiB wishlist + Longhorn 2× overhead. Verified 96 pods Running.
* Data disks at 150 GiB on `ssd01` give headroom for 2× replicas + SeaweedFS volumes.
* Placement correct: replicas only on workers with data disks; Cilium coverage unchanged.
* Zero cost; defers 64 GiB upgrade.

### Negative / Risks

* **Host tight (~96%: `6 + 18 + 4 + 2 = 30 GiB`).** Only ~1 GiB free for bursts/backups/rebuilds. Relief: workers 6→5 GiB (`6+15+4+2=27 GiB → 87%`, Alt F).
* **SPOF:** loss of `talos-cp1` = API/etcd down. RTO 15–30 min (`apply -replace` + bootstrap ≈ 20 min with healthy snapshots).
* **No rolling CP upgrade:** `~2–4 min` API downtime per Talos/K8s upgrade. Workloads keep running on cached manifests; announce maintenance window.
* **Backups mandatory:** hourly `talosctl etcd snapshot` + Velero/Restic to S3-compatible storage + Terraform state in S3 backend; monthly restore drill. Without them, CP disk loss = rebuild etcd + re-push GitOps, PVC data gone.
* **Monitoring gap:** need `KubeControlPlaneDown` / `EtcdMembersDown` (>2m) + Velero-failure alerts in same channel; `metrics-server` present (verified 2026-09-14, `kubectl top` available).
* **Longhorn degraded on worker loss:** with `replicas: 2`, one worker down = single remaining replica until return. `replicas: 3` deferred until 6–8 GiB workers.
* **CPU overcommit (144–181% limits).** RAM fixed; `pressure/io` is next bottleneck.

**Mitigations adopted:** CP at 6 GiB (live 71% — 4 GiB proved tight); TrueNAS lowered to 2c/4GB; `cpu_units` 200 on the control plane only + affinity `2-5,8-11` (workers float since 2026-09-29); backup runbook in `docs/operations.md` + green restore drill as gate; `PDB maxUnavailable: 0` for `cilium-operator`, `longhorn-manager`, `argocd`.

## Alternatives Considered

| # | Alternative | Why not chosen |
|---|-------------|----------------|
| A | 3×6 rightsized (keep HA, tune inflight/QoS/replicas) | Only +0.5–0.8 GiB/node. Keeps quorum, sacrifices learning goal. Deferred as tuning on top of chosen topology. |
| B | 3×6 + 1×4 worker | +2.5 GiB allocatable only, host 88%, worse loadavg on 6c. Still needs ≥2 workers for 2× replicas. |
| C | Externalize TrueNAS | Correct, no hardware. Revisit with second host — then `1×6+3×6` minus TrueNAS fits at ~84% (`6+18+2=26`). |
| D | 64 GiB upgrade | Ideal long-term. Blocked on budget. **Explicit revert trigger** (see below). |
| E | K3s / single-node | Loses Talos immutability + Image Factory + Terraform contract. Rejected — learning goal is Talos/K8s. |
| F | 1×6 + 3×5 balanced (`27 GiB → 87%`) | **Best fallback if 96% proves tight.** Workers ~4.3 GiB allocatable, restores margin. Use if host >85% sustained or loadavg >10. |

Chosen: **current `1×6 + 3×6`** (reversible in one `tfvars` edit). Fallback: **F**.

## Restore Guide — back to 3 control-planes

Run when `pve01` has ≥64 GiB usable or a second PVE node exists:

1. Install RAM / add `pve02`; verify ≥60 GiB usable.
2. Expand `terraform.tfvars`: 3× CP entries (`6*1024`, `allow_scheduling=false`, 150 GiB data disk on `ssd01`); workers stay `3×6` (grow to `3×8` later after verifying <80% host).
3. `just provider=proxmox env=prod tf-apply` — boots `talos-cp2/cp3`.
4. Join etcd: `talosctl -n 10.10.0.11 etcd members` → `talosctl -n 10.10.0.12 etcd join --nodes 10.10.0.11` → same for `.13` → verify 3 members + 6 nodes Ready. Fallback: `talosctl -n <new-cp> bootstrap` with existing `machine_secrets`.
5. Optional: re-enable Longhorn scheduling on CPs for `replicas: 3` across 6 nodes; else keep workers-only.
6. Verify HA: `etcd status` on all three, kill one CP VM and confirm API via another CP IP.
7. Mark this ADR `Superseded` and create successor (e.g. `005-ha-control-plane-restored.md`).

## References

* `environments/proxmox/prod/terraform.tfvars` — `nodes_cp` / `nodes_worker`.
* `modules/proxmox/main.tf` — VM shape, SCSI `scsi0` OS + dynamic `scsiN` disks (`virtio-scsi-single`), `data_volume_patch` / `UserVolumeConfig "data"` / 5 GiB swap backing disk.
* `modules/talos-cluster/main.tf` — `allow_scheduling` / taint, `control_plane_nodes`, mounts.
* `docs/decisions.md`, `docs/architecture.md`, `docs/adr/003-sdn-snat-runtime-drift.md`.
* Measurements: `talosctl ps` / `memory`, `pve01 status`, `kubectl describe nodes`.
* Companion repo `gitops-platform/docs/adrs/` — platform ADRs.

---

*ADR 004 follows MADR 2.3.0, matching ADR 001/002/003. Provenance: 30.97 GiB usable, old 3×6 → 1.4 GiB AVAILABLE / loadavg 21 / etcd fdatasync 1.5–2s, wishlist +4–5 GiB; current 1×6+3×6 + TrueNAS 2c/4GB + 150 GiB data disks (local-lvm OS, ssd01 data), host ~96% (30/30.97), 96 pods Running. Contact: Seom88.*
