# 5. Longhorn Storage Contract: Infra Provides Disks, GitOps Owns Longhorn

* **Status:** Accepted
* **Date:** 2026-09-11
* **Deciders:** Seom88
* **Tags:** talos, longhorn, storage, gitops, user-volume-config, homelab

## Context

Where this ADR lives:

This decision is about the **storage ownership boundary** — what the cluster
substrate must provide vs what the GitOps layer manages. It belongs in
`infra-terraform-talos/docs/adr/` (this repo). The companion GitOps repo
`gitops-platform` owns the Longhorn lifecycle decisions
(ADR-003 moved Longhorn+ArgoCD to infra, ADR-005 moved Longhorn back to
GitOps as wave-0 after dropping `redis-ha`).

This repo just finished two changes that force the contract to be explicit:

* Talos `1.13.9` → `1.14.0` removed `machine.kubelet.extraMounts` by design
  (`KubeletConfig` in 1.14 has no `extraMounts` field). The old bind
  `/var/mnt/data` → `/var/lib/longhorn` is gone.
* Disks from `terraform.tfvars` (`prod` workers: `data` 100GB) are now wired
  to dynamic `UserVolumeConfig` docs — 1 name = 1 UVC → `/var/mnt/<name>`.

Open question was: if Longhorn is a prerequisite for almost everything else,
should it live in infra? And does adding a 2nd/3rd disk require a GitOps change?

## Decision

**Longhorn stays in GitOps as wave-0. Infra provides only machine prerequisites.**

| Concern | Owner | What |
|---------|-------|------|
| System extensions | infra (`modules/talos-image`) | `siderolabs/iscsi-tools`, `siderolabs/qemu-guest-agent`, `siderolabs/util-linux-tools` via `exact_filters` |
| Disk mounts | infra (`modules/proxmox`, `modules/libvirt`, `modules/talos-cluster`) | 1 `UserVolumeConfig` per disk name → `/var/mnt/<name>` (`data` → `/var/mnt/data`), `minSize` derived from `disks[].size` |
| Longhorn chart + settings | GitOps (`platform/longhorn/`, wave 0) | chart version, `defaultSettings.defaultDataPath: /var/mnt/data`, StorageClasses, `longhorn-csi-wait` Job gating later waves |
| Extra disks (2nd/3rd) | GitOps day-2 per node | register `/var/mnt/data2` in `spec.disks` of `nodes.longhorn.io` (UI or `kubectl edit`); **no Helm/`values.yaml` change** |

`defaultDataPath` is set once to `/var/mnt/data` and never changes per disk.
It only defines the default disk on node registration. Extra UVCs are picked
up by Longhorn node config, not by Helm.

## Consequences

### Positive

* Single responsibility per repo — provisioning in infra, declarative apps in GitOps (completes GitOps ADR-005).
* Storage ordering is declarative: sync waves + CSI readiness gate instead of
  Terraform dependencies or script steps.
* Longhorn gets Git versioning, ArgoCD self-heal and rollback; infra stays
  distro-agnostic and free to evolve (Talos today, Ansible/cloud tomorrow).
* Scaling disks is additive: new UVC in Terraform, new `spec.disks` entry in
  Longhorn — no chart reinstall, no `defaultDataPath` churn.

### Negative / Risks

* Two-step bootstrap — infra `platform/` apply first, then GitOps sync.
* Extra-disk registration is manual per node (`nodes.longhorn.io`) until
  label+annotation automation (`create-default-disk-labeled-nodes`) is adopted.
* Multi-disk `diskSelector` is best-effort (`!system_disk` + size floor):
  harden to `by-id`/`serial` matches post-bootstrap via `talosctl get disks`
  before adding the 2nd disk, or two UVCs can race for the same disk.
* First apply after removing `extraMounts` does a rolling `talos_machine`
  reboot per node — use `-parallelism=1`, verify `volumestatus` +
  `nodes.longhorn.io` Ready/Schedulable between nodes.

## References

* `modules/talos-image/` — canonical schematic source (`exact_filters` → `schematic` → `urls`).
* `modules/proxmox/main.tf`, `modules/libvirt/cluster.tf` — dynamic `data_volume_patches`.
* `modules/talos-cluster/main.tf` — no `extraMounts`; `KubeNodeConfig` + `UnattendedInstallConfig` (Talos 1.14).
* Companion repo: `platform/longhorn/values.yaml` (`defaultDataPath: /var/mnt/data`),
  `docs/adrs/003-argocd-longhorn-to-infra.md`,
  `docs/adrs/005-longhorn-back-to-gitops.md`.
* Sidero docs: Longhorn V1 guide (UVC → `/var/mnt/longhorn`, no `extraMounts`),
  `UserVolumeConfig` auto-mount + kubelet propagation, upgrading-talos
  ("`.machine.kubelet.extraMounts` has no equivalent in the new documents").
