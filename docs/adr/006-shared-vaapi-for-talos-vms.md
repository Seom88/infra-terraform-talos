# 6. No Shared VAAPI/QuickSync to Talos VMs on 8700T — CPU-only Immich

* **Status:** Accepted
* **Date:** 2026-09-22
* **Deciders:** Seom88
* **Tags:** proxmox, gpu, vaapi, quicksync, immich, talos, virtio-gpu, homelab

## Context

Host `PVE01`: i7-8700T / UHD 630 (`8086:3e92`, Gen9.5 Coffee Lake), PVE
9.2.18, kernel `7.0.14-16-pve`, `/dev/dri/renderD128` + `card1` present,
`i915` loaded, `libvirglrenderer1 1.1.0-2` + Mesa 25.0.7, no
`virgl-server`. Provisioning via `infra-terraform-talos/modules/proxmox`
(`bpg/proxmox` 0.113.1, Talos VMs `q35`/`ovmf`, no `vga` block → default
`std`). Immich runs in the secure GitOps repo with a minimal CPU-only
`values.yaml`.

Question investigated 2026-09-22: is there any sharing option beyond
`virtio-gl` (VirGL) and Venus that gives VMs real VAAPI/QuickSync — on
this old Intel or in general — before locking in CPU-only?

## Decision

**Keep CPU-only Immich in the Talos VM on the 8700T. There is no
production-usable shared-VAAPI path to a Proxmox VM on this host.**

| Option | Verdict | Why |
|--------|---------|-----|
| `hostpci` passthrough | 1 VM only | Full GPU to one guest; nothing shared. |
| `virtio-gl` (VirGL) | Rejected | OpenGL only; no QuickSync/VAAPI/OpenVINO → useless for Immich transcode (`QSV`/`VAAPI`/`NVENC`/`RKMPP`) and ML. |
| Venus (Vulkan) | Rejected | Needs `virgl-server` + pve-devel patches (Aug-2026) not exposed by provider; Immich has no Vulkan-Video preset anyway. |
| `gfxstream` / `rutabaga` | Rejected | GLES/Vulkan forwarding only; no video encode/decode path (QEMU docs). |
| `virtio-video` / `vhost-user-video` | Rejected | Exists only in crosvm (WIP, out-of-tree guest driver); no QEMU device; backends are ChromeOS-only or software decode. No PVE integration. |
| `virglrenderer` VA-API video (`-Dvideo=enabled` + `VIRGL_RENDERER_USE_VIDEO`, `src/vrend_video.c`) | Watch only | Real experimental code, but nothing in QEMU sets the flag and PVE wires nothing up. Research project, not a homelab solution. |
| i915 DRM native context | Watch only | Needs host 6.13+ + virglrenderer 1.3.0+ + guest 6.14 / Mesa 26.1; undocumented whether the media engine passes through. Re-check in 6–12 months. |
| GVT-g via PVE 7 / kernel 5.15 downgrade | Rejected | Did expose the media engine (`i915-GVTg_V4_*`), and 8086:3e92 is in the HW window — but upstream archived Oct-2024 with known security escapes, PVE 7 EOL. Freezing a hypervisor on CVEs for one container's transcode is indefensible. |
| SR-IOV on this GPU | Impossible | 8th-gen has no SR-IOV (11th G+ / 12th+ only); GVT-g discontinued, no kernel 7 support. |
| NVIDIA vGPU / AMD MxGPU on consumer cards (GTX 1650, RX 7700S, 680M) | Rejected | Datacenter-only + license; consumer blocked. Passthrough gives 1 VM VAAPI/NVENC but no sharing; ROCm does not cover 7700S-mobile/680M for ML. |
| `args:` / `hostpci` mdev tricks | Rejected | `args:` still exists (`qm.conf.5.html` 9.2.4) but there is no QEMU device conjuring guest `/dev/dri` from host VAAPI; `mdevctl types` is empty without GVT-g/SR-IOV/vGPU. |

The only shared-acceleration architecture on this host that preserves
the Talos/GitOps flow is a bare-metal Talos worker + Intel GPU stack
(an escape hatch, not the current path — see Consequences). LXC
`/dev/dri` bind-mount is out of scope: Talos needs its own kernel as a
full OS/VM and cannot run inside an LXC container (shared host kernel),
and running Immich in a Proxmox-native LXC would abandon the
Talos/GitOps flow this estate standardizes on.

General homelab rule established: shared VAAPI to VMs means Intel
11th+ with SR-IOV — e.g. Alder Lake i5-12450H + `i915-sriov-dkms` (up
to 7 VFs, each with real `/dev/dri`).

## Consequences

### Positive

* No fragile downgrades, custom QEMU/virglrenderer builds, or license-violating hacks on the hypervisor.
* Immich stays in the Talos/GitOps flow; zero app changes needed later — a future VF shows up as symmetric `/dev/dri`.
* UHD 630 limits documented: H.264/HEVC-8bit QSV + VP9 decode, no AV1 (Gen9.5) — codec choice stays honest.

### Negative / Risks

* Transcode + ML (CLIP) stay on 6c/12t CPU; heavy 4K libraries will feel it.
* Bare-metal Talos worker keeps GitOps but removes a node from the Proxmox cluster and pins a Talos schematic + driver versions.

## Re-check watchlist (revisit, do not build on today)

* [ ] `virglrenderer` `video=enabled` / `VIRGL_RENDERER_USE_VIDEO`: does PVE's packaged version enable it, and does QEMU set the flag? Check `pveversion -v` + `qm showcmd` + source.
* [ ] i915 DRM native context: does it carry media-engine/VAAPI traffic or render/compute only? Needs test on host 6.13+ / guest 6.14+ / Mesa 26.1+.
* [ ] Venus `VK_KHR_video_*` forwarding: unconfirmed; irrelevant to Immich until Immich ships a Vulkan-Video preset.
* [ ] Alder Lake route: `i915-sriov-dkms` + `i915.enable_guc=3` + `i915.max_vfs=7`, Proxmox PCI resource mapping for VFs, guest i915 + `intel-media-driver` + `vainfo`.
* [ ] Freshness: host pins above postdate the newest verified upstreams (virglrenderer 1.3.0 Jun-2026, i915-sriov 2026.05/08 tags) — re-verify versions on the host before acting.

## References

* `modules/proxmox/` (`bpg/proxmox` 0.113.1) — Talos VMs `q35`/`ovmf`, no `vga` block.
* Secure repo Immich `values.yaml` (minimal, CPU-only).
* QEMU docs: virtio device list, `virtio-gpu.html` (virgl vs rutabaga backends, native-context requirements).
* virglrenderer: `src/vrend_video.c`, `-Dvideo=enabled` / `VIRGL_RENDERER_USE_VIDEO` usage notes.
* crosvm book: `devices/video.md`; `rust-vmm/vhost-device-video` staging crate.
* Intel `intel/gvt-linux` (archived Oct-2024), kernel `gpu/i915.html`, ArchWiki GVT-g deprecation.
* Immich docs: hardware transcoding (`QSV`/`VAAPI`/`NVENC`/`RKMPP`, `/dev/dri` mounts).
* Proxmox: `qm.conf.5.html` (`args:`), NVIDIA vGPU wiki, PVE 9 + kernel 6.14 + `i915-sriov-dkms` issue reports.
* Investigation record: 2026-09-22 research (general worker) — full findings in session history.
