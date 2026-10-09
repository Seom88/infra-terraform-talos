# Variables

> All input variables for Proxmox, Libvirt, and the shared `talos-cluster` module — verbatim from the original README, cleaned and cross-linked.

[← Back to README](../README.md) · [Architecture →](./architecture.md) · [Networking →](./networking.md)

All 4 envs ship input validations — 57 blocks total — semver for `talos_version`/`kubernetes_version`/`argocd_version`, CIDR for `network_cidr`, IP for `gateway`/`cp_ips`, non-empty `cluster_name`/`env_name` + `^(dev|prod)$`, nullable guards for `machine_secrets`/`client_configuration`. See [Validation & Quality](../README.md#validation--quality) and [CI/CD](./ci-cd.md).

## Proxmox

| Variable | Description | Default |
|----------|-------------|---------|
| `env_name` | Environment name (`dev` / `prod`); selects secrets paths — validated `^(dev\|prod)$` | — |
| `endpoint` | Proxmox API URL (e.g. `https://10.10.10.1:8006`) | — |
| `api_token` | Proxmox API token in format `user@realm!tokenid=secret` | — |
| `username` | Proxmox API user — legacy, commented out in code | — |
| `password` | Proxmox API password — legacy, commented out in code | — |
| `ssh_username` | SSH user for Proxmox node operations | `root` |
| `ssh_node_address` | SSH address for the Proxmox node (e.g. Tailscale hostname) | — |
| `insecure` | Skip TLS verification | `false` |
| `node_name` | Proxmox node for image download | — |
| `gateway` | VM default gateway | — |
| `network_bridge` | Proxmox network bridge (must match SDN VNet id `talosvn` when using SDN) | `vmbr0` |
| `sdn_zone` | SDN zone id for the Talos network | `talos` |
| `network_cidr` | CIDR for the SDN VNet subnet (must contain node IPs) | `10.10.0.0/24` |
| `network_mtu` | MTU for the SDN zone | `1500` |
| `network_snat` | Enable SNAT on the SDN subnet (MASQUERADE for VM egress) | `true` |
| `datastore_iso` | Datastore for ISO/raw images | `local` |
| `nodes_cp` | Control plane nodes (hostname, ip, cores, memory, proxmox_node, disk_size, datastore, allow_scheduling — all required; `cpu_units`/`cpu_affinity`/`disks[]` optional) | — |
| `nodes_worker` | Worker nodes (hostname, ip, cores, memory, proxmox_node, disk_size, datastore — all required; `cpu_units`/`cpu_affinity`/`disks[]` optional) | — |
| `nodes_[cp,worker].cpu_units` | Proxmox CPU shares weight (e.g. `200` CP / `100` workers); applied via `just affinity-sync` (`root`, `qm set --cpuunits`) | — |
| `nodes_[cp,worker].cpu_affinity` | Pinned host CPU set (e.g. `"2-5,8-11"`); applied via `just affinity-sync` (`root`, `qm set --affinity`) | — |
| `nodes_[cp,worker].disks[]` | Extra data disks (`{ name, size, datastore[, ssd] }`) → scsiN + one `UserVolumeConfig` per distinct name (`/var/mnt/<name>`); `ssd` optional, default `true` | — |
| `talos_version` | Talos Linux version | `1.14.1` |
| `argocd_version` | ArgoCD Helm chart version | `10.9.2` |
| `install_disk_match` | Talos install disk selector (e.g. `/dev/sda` on Proxmox) — required, no module default | — |
| `enable_health_check` | Enable `talos_cluster_health` gate (set `false` for destroy) | `true` |

> Tailscale node extension is disabled ([ADR 001](./adr/001-remove-tailscale-extension.md)): node extension variables are commented out in `variables.tf` as `Tailscale extension disabled`. Subnet routing only (`10.10.0.0/24`). API uses direct per-node IPs (health-gated, removed in 2.0.0). See [Networking](./networking.md).

## Platform (`modules/platform`)

| Variable | Description | Default |
|----------|-------------|---------|
| `cilium_version` | Cilium Helm chart version (`cilium/cilium`) — semver validated | `1.20.2` |
| `cilium_namespace` | Namespace for Cilium | `kube-system` |
| `cilium_values_file` | Custom Cilium Helm values path (defaults to `values/cilium/values.yaml`) | `""` |
| `cilium_operator_replicas` | Cilium operator replicas (`1..3`, leader election; `1` dev, `2` HA) — sets `operator.replicas` | `1` |
| `gateway_api_crds_version` | Gateway API CRDs chart version (`christianhuth/gateway-api-crds`) | `1.2.4` |
| `gateway_api_version` | Alias for `gateway_api_crds_version` (same chart) | `1.2.4` |
| `gateway_api_crds_namespace` | Namespace for Gateway API CRDs release (CRDs cluster-scoped) | `kube-system` |
| `gateway_api_channel` | Gateway API channel `standard` / `experimental` → `standard.enabled` / `experimental.enabled` | `standard` |

> Cilium values: `modules/platform/values/cilium/values.yaml` (Sidero Without kube-proxy + Gateway API: `ipam=kubernetes`, `kubeProxyReplacement=true`, `k8sServiceHost=localhost:7445` KubePrism, `cgroup.autoMount=false`, `gatewayAPI.enabled=true`). DAG: `gateway_api` → `cilium` → `wait_nodes` → `argocd`.

## Libvirt

| Variable | Description | Default |
|----------|-------------|---------|
| `nodes_cp` | Control plane nodes (hostname, ip, mac, cores, memory, disk_size, pool, allow_scheduling — all required; `disks[]` optional) | — |
| `nodes_worker` | Worker nodes (hostname, ip, mac, cores, memory, disk_size, pool — all required; `disks[]` optional) | — |
| `nodes_[cp,worker].disks[]` | Extra data disks (`{ name, size }`) → vdb..N + one `UserVolumeConfig` per distinct name (`/var/mnt/<name>`) | — |
| `install_disk_match` | Talos install disk selector (`/dev/vda` on libvirt) — required, no module default | — |
| `pool_name` | Dedicated storage pool name | `talos-pool` |
| `pool_path` | Filesystem path for the pool | `/var/lib/libvirt/images/talos` |
| `gateway` | Default gateway IPv4 | `10.0.1.1` |
| `network_cidr` | Subnet CIDR for the Libvirt NAT network | `10.0.1.0/24` |
| `secureboot` | Enable UEFI SecureBoot (q35) | `true` |
| `talos_image_cache_dir` | Local cache for nocloud raw images | `~/.cache/talos-images` |
| `cluster_name` | Talos / Kubernetes cluster name | `talos-cluster` |
| `talos_version` | Talos Linux version — semver validated | `1.14.1` |
| `kubernetes_version` | Kubernetes version — semver validated | `1.37.0` |
| `longhorn_enabled` | Deprecated no-op: Longhorn uses `defaultDataPath=/var/mnt/data` with no kubelet `extraMounts`; UVCs come from `disks[]` via `extra_config_patches` | `true` |
| `extra_config_patches` | Additional Talos machine config patches | `[]` |
| `env_name` | Environment selector — validated `^(dev\|prod)$` (`dev` in `libvirt/dev`, `prod` in `libvirt/prod` + both proxmox envs) | `dev` |
| `argocd_version` | ArgoCD Helm chart version — semver validated | `10.9.2` |
| `enable_health_check` | Enable `talos_cluster_health` gate (set `false` for destroy) | `true` |

> See above — same Tailscale note as Proxmox above.

## Shared (`modules/talos-cluster`)

| Variable | Providers | Description | Default |
|----------|-----------|-------------|---------|
| `talos_version` | both | Talos Linux version | `1.14.1` |
| `installer_image` | module | Installer container image for `talos_machine.image` (from the Image Factory `urls` data source, e.g. `factory.talos.dev/nocloud-installer-secureboot/<schematic-id>:v1.14.1`). Required; flavor selected by the caller (Proxmox always secureboot, libvirt via `var.secureboot`) | — |
| `cp_allow_scheduling` | module | Per control plane node: allow workloads on that node (from `nodes_cp[].allow_scheduling`). Applied per node via the Talos `KubeNodeConfig` taint-delete machine-config patch (pre-1.14: `cluster.allowSchedulingOnControlPlanes`, Sidero docs) | — |

> **Note**: since explicit-module-vars, `modules/*` carry no defaults (everything required except documented `null`-optionals); every env declares `cluster_name`, `kubernetes_version`, `longhorn_enabled`, `extra_config_patches`, `drain_on_upgrade`, and `install_disk_match` explicitly and passes them through. Tailscale node extension and the former shared API address were removed in 2.0.0 (direct per-node IPs via health gate).

## Validation notes

- 57+ validation blocks across `modules/talos-cluster`, `modules/proxmox`, `modules/libvirt`, `modules/platform` and all 4 envs (`environments/proxmox/{dev,prod}`, `environments/libvirt/{dev,prod}`).
- `drain_on_upgrade` — `bool`, default `false`, parameterized and platform-aware (`false` for Longhorn prod, opt-in `true` for dev). Controls whether nodes are drained during `talos_machine` rolling upgrades.
- Provider versions are pinned: `bpg/proxmox 0.114.0`, `dmacvicar/libvirt ~>0.9.8`, `siderolabs/talos 0.12.0-beta.0` ([ADR 002](./adr/002-pinned-talos-provider-alpha.md)), `helm ~>3.2`, `kubernetes ~>3.0`, `time ~>0.14`.
- `kubernetes_version` (`1.37.0` default in every env) is now **managed by Renovate** via `customManagers` regex (`github-releases/kubernetes/kubernetes`, semver) — patch automerges, minor stays manual (Talos 1.14 supports 1.36-1.37). `talos_cluster.kubernetes_version` is pinned per-machine (`v${var.kubernetes_version}`) with `ignore_kubernetes_upgrade_drift = true` to keep upgrades driven by `talos_cluster`. See [CI/CD](./ci-cd.md).

---

Next: [Operations →](./operations.md) · [Usage →](./usage.md) · [Platform →](./platform.md)
