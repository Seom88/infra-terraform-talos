# Networking

> SDN, NAT, and Tailscale subnet routing — how the cluster is isolated, how it reaches the internet, and how you reach it.

[← Back to README](../README.md) · [Architecture →](./architecture.md) · [Operations →](./operations.md)

## Overview

| Layer | Proxmox (`talosvn`) | Libvirt (`virbr-talos`) |
|-------|---------------------|--------------------------|
| Bridge | SDN VNet `talosvn` / Linux bridge `prod` | `virbr-talos` |
| Subnet | `10.10.0.0/24` | `10.0.1.0/24` |
| Reachability | Tailscale subnet router `10.10.0.0/24` | NAT + subnet route (same model) |
| Internet egress | SNAT MASQUERADE (`snat = true`) | NAT forward + firewalld masquerade |
| DNS / DHCP | Static IPs via cloud-init | DHCP reservations + DNS from MACs |

## Proxmox — SDN `talosvn`

Terraform creates the full SDN stack in `modules/proxmox/network.tf`:

```
proxmox_sdn_zone_simple (talosvn) → proxmox_sdn_vnet (prod) → proxmox_sdn_subnet (10.10.0.0/24, snat=true) → proxmox_sdn_applier (PUT /cluster/sdn)
```

- **Zone** — simple zone `talos` covering `var.node_name` (`pve01`). The VNet id `prod` is the Linux bridge name on the PVE node and must match `var.network_bridge` (max 8 chars, hence `talosvn`).
- **VNet** — `talosvn` (the bridge). VMs attach via `network_device { bridge = var.network_bridge }`.
- **Subnet** — `10.10.0.0/24` with `snat = true`. Proxmox renders this as `post-up iptables -t nat -A POSTROUTING -s '10.10.0.0/24' -o vmbr0 -j SNAT --to-source <node-ip>` in `/etc/network/interfaces.d/sdn`. VMs get outbound internet via MASQUERADE; nothing from outside reaches them directly.
- **Applier** — `proxmox_sdn_applier` performs `PUT /cluster/sdn`. Without it the bridge does not exist on the node and VM creation fails. VMs `depends_on` the applier.
- **Reboot safety** — `terraform_data.sdn_ensure_applied` installs `pve-sdn-ensure.service` on the PVE node (`pvesh set /cluster/sdn || ifreload -a` on boot, `After=network.target pve-cluster.service`). See [ADR 003](./adr/003-sdn-snat-runtime-drift.md). The service ensures the bridge `prod` and `MASQUERADE` rule for `10.10.0.0/24` persist across reboots; without it a reboot can drop MASQUERADE and cause `10.10.0.12 -> 1.1.1.1:53 i/o timeout` and `Waiting for time sync` blocking `talos_cluster_health`.

```hcl
# modules/proxmox/network.tf — key knobs
variable "sdn_zone"     { default = "talos" }
variable "network_bridge" { default = "vmbr0" }  # must match VNet id "talosvn" when using SDN
variable "network_cidr" { default = "10.10.0.0/24" }
variable "network_mtu"  { default = 1500 }
variable "network_snat" { default = true }
```

> Proxmox datacenter firewall is explicitly disabled on the VM NICs via `network_device { firewall = false }` so it does not override the SDN MASQUERADE.

## Libvirt — NAT `virbr-talos`

Terraform creates in `modules/libvirt/network.tf` / `pool.tf` / `image.tf` / `vms.tf`:

- **NAT network** — `virbr-talos` bridge `10.0.1.0/24` (`libvirt_network.talos` with `forward nat` + `bridge.zone=libvirt`). DHCP reservations and DNS entries are derived from node MACs; MACs are deterministic (`52:54:00:xx:yy:zz` via `md5(hostname)`) when `mac` is omitted.
- **Storage pool** — `talos-pool` at `/var/lib/libvirt/images/talos` (`modules/libvirt/pool.tf`).
- **Image cache** — nocloud raw images (`nocloud-amd64.raw.xz` or `nocloud-amd64-secureboot.raw.xz` when `secureboot = true`) downloaded via Talos Image Factory and cached persistently at `~/.cache/talos-images` (`modules/libvirt/image.tf`). Only the first apply downloads.
- **Host firewall** — libvirt creates the network, but the host firewall must have masquerade/forward on the `libvirt` zone. Run once per hypervisor:

  ```bash
  just setup-host   # firewalld: add-masquerade + add-forward on zone libvirt, idempotent
  ```

  Or manually:

  ```bash
  sudo firewall-cmd --zone=libvirt --add-masquerade --permanent && sudo firewall-cmd --reload
  sudo firewall-cmd --zone=libvirt --add-forward --permanent && sudo firewall-cmd --reload
  ```

## Cilium CNI (eBPF Data Plane)

Cilium provides the pod network, service load-balancing, network policy, and Gateway API data plane via eBPF — replacing kube-proxy and kube-router.

### Why Cilium

- **eBPF data plane** — kernel-level forwarding, observability, and policy enforcement without iptables churn.
- **kubeProxyReplacement** — `kubeProxyReplacement=true`; kube-proxy is disabled at the Talos level and Cilium handles ClusterIP/NodePort.
- **Gateway API** — `gatewayAPI.enabled=true` with ALPN and AppProtocol support for Gateway/HTTPRoute.

### Talos prerequisites

Talos is configured with no built-in CNI or kube-proxy so Cilium can own the data plane:

```yaml
# modules/talos-cluster/main.tf:40-51 (multi-doc machine config patch)
apiVersion: v1alpha1
kind: KubeFlannelCNIConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubeProxyConfig
enabled: false
```

KubePrism provides the in-cluster API endpoint for Cilium:

- `k8sServiceHost=localhost`, `k8sServicePort=7445` (KubePrism load-balanced API on each node).

Reference: Sidero Labs [Deploying Cilium — Without kube-proxy + Gateway API](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium) (also mirrored at `https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium#cli-install`).

### Deployment DAG

```
helm_release.gateway_api (christianhuth/gateway-api-crds 1.2.4, standard)
  → helm_release.cilium (cilium/cilium 1.20.2, wait=true timeout 1800, values modules/platform/values/cilium/values.yaml)
    → terraform_data.wait_nodes (kubectl wait --for=condition=Ready nodes)
      → helm_release.argocd
```

Why this order:

| Step | Reason |
|------|--------|
| Gateway API CRDs first | `gatewayAPI.enabled=true` requires CRDs to exist; otherwise Cilium fails to install. CRDs are Helm-managed via `christianhuth/gateway-api-crds` (`standard` channel). |
| Cilium before wait_nodes | Nodes become `Ready` only when a CNI is present. The DAG is `gateway_api → cilium → wait_nodes → argocd`. This ordering ensures Gateway API CRDs exist before Cilium (`gatewayAPI.enabled=true` requires them) and that `wait_nodes` runs only after the CNI is present. The gate re-triggers when the `kubeconfig` hash changes. |
| wait_nodes before ArgoCD | ArgoCD needs a Ready cluster with networking; the gate guarantees CNI + API are healthy before the GitOps engine starts. |

Helm settings: `wait=true` with `timeout=1800` on the Cilium release; `operator.replicas` is parameterized (`var.cilium_operator_replicas`, `1` for dev/single-node, `2` for single-CP prod, leader election).

### Key values summary

Source: `modules/platform/values/cilium/values.yaml` (Sidero Without kube-proxy + Gateway API pattern).

| Key | Value | Purpose |
|-----|-------|---------|
| `ipam.mode` | `kubernetes` | Pod CIDR allocation via Kubernetes. |
| `kubeProxyReplacement` | `true` | eBPF-based service handling; kube-proxy disabled. |
| `k8sServiceHost` / `k8sServicePort` | `localhost` / `7445` | KubePrism localhost API. |
| `socketLB.enabled` / `hostNamespaceOnly` | `true` / `true` | Enables `kubectl port-forward` / `exec` / `logs` — Cilium is configured with `socketLB.enabled=true` and `hostNamespaceOnly=true` so socket LB is restricted to the host netns and does not intercept `127.0.0.1` connect in pod netns (RST). Cilium 1.20 defaults `socketLB.enabled=false` (`bpf-lb-sock:false` when disabled), so `enabled=true` is required. |
| `cgroup.autoMount.enabled` / `hostRoot` | `false` / `/sys/fs/cgroup` | Talos cgroup layout — do not auto-mount, use host root. |
| `securityContext.capabilities` | 12 caps (ciliumAgent + cleanCiliumState) | Talos-required capabilities (`NET_ADMIN`, `SYS_ADMIN`, etc.). |
| `gatewayAPI.enabled` / `enableAlpn` / `enableAppProtocol` | `true` | Gateway API + ALPN + AppProtocol. |

### Observability

| Component | Detail |
|-----------|--------|
| Hubble | `hubble.enabled=true`, `relay.enabled=true`, `ui.enabled=true` — flow observability. |
| Metrics | `hubble.metrics.enabled` includes `dns`, `drop`, `tcp`, `flow`, `port-distribution`, `icmp`, `httpV2` with `enableOpenMetrics=true` on port `9965`. |
| Prometheus | `prometheus` (agent, `9962`), `operator.prometheus` (`9963`), `envoy.prometheus` (`9964`), `hubble.metrics` (`9965`), `hubble.relay.prometheus` (`9966`) — all with `ServiceMonitor` (`release: monitoring`, `interval: 30s`). |
| Dashboards | `dashboards.enabled=true` and `hubble.metrics.dashboards.enabled=true` + `operator.dashboards.enabled=true` with label `grafana_dashboard: "1"` for Grafana discovery. |

### Interaction with Tailscale

- **Cilium owns pod networking** — pod-to-pod, pod-to-service, and NetworkPolicy are handled by Cilium/eBPF regardless of how the node is reached.
- **Tailscale owns node reachability** — subnet routing (`10.10.0.0/24` via the Proxmox host, `10.0.1.0/24` for libvirt) exposes the KubePrism API and VM subnet to operators/CI. The Talos Tailscale extension is disabled (see ADR 001).
- **Tailscale Ingress** is deployed as a GitOps app in the companion repo (`04-tailscale`); it programs Tailscale tailnet exposure on top of Cilium networking — the two layers do not conflict.
- `CiliumNetworkPolicy` resources are managed by ArgoCD (2 infra-owned policies in `argocd` namespace) — see [Platform](./platform.md).

## Tailscale subnet routing (both providers)

The Tailscale **Talos extension** (`siderolabs/tailscale`) is disabled. Reachability to `10.10.0.0/24` (Proxmox) and `10.0.1.0/24` (Libvirt) is **subnet routing only** — see [ADR 001](./adr/001-remove-tailscale-extension.md).

### Proxmox — expose `10.10.0.0/24`

> **Network reachability (Proxmox SDN):** Terraform must be able to reach the cluster IPs (`10.10.0.0/24`). The `talosvn` SDN VNet is isolated — VMs get outbound internet via SNAT (`subnet snat = true`), but traffic from outside cannot reach them directly. If you are not on the same network as the Proxmox host, expose the subnet through Tailscale from the Proxmox node (prod):

```bash
# 1. On the Proxmox host (subnet router — it already runs Tailscale)
sudo tailscale set --advertise-routes=10.10.0.0/24
```

2. Approve the route: Tailscale admin console → **Machines** → the host row → **Subnets** → **Edit route settings** → tick `10.10.0.0/24` → **Save**
3. On the device running Terraform: `sudo tailscale set --accept-routes` (Linux only — Windows/macOS accept routes by default)

Without the route, the `talos_cluster_health` gate waits until its 15 m timeout because it cannot reach the control plane endpoints (direct per-node IPs).

### Libvirt

Libvirt uses the same subnet-routing model for remote reachability; no `TF_VAR_tailscale_auth_key` is required on nodes (extension disabled).

### CI

`tailscale/github-action@v4` is used in CI only for subnet-route reachability to `10.10.0.0/24` (no Tailscale extension on nodes). Secrets required: `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` with tags `tag:terraform` and scopes `devices:core:write`, `auth_keys:write`.

## Reachability troubleshooting

| Symptom | Cause | Remediation |
|---------|-------|-------------|
| `talos_cluster_health` hangs 15 m, `Still reading...` | No route to `10.10.0.0/24` | Check `tailscale status`, `tailscale set --accept-routes`, approve subnet in admin console |
| `read udp 10.10.0.12:xxxxx->1.1.1.1:53: i/o timeout` after PVE reboot | SDN SNAT runtime drift (bridge `prod` / MASQUERADE lost) | `ssh root@pve01 'systemctl status pve-sdn-ensure.service; iptables -t nat -L POSTROUTING -n \| grep MASQUERADE'` — service should be `enabled` and rule present; manual heal: `pvesh set /cluster/sdn` |
| `lookup time.cloudflare.com ... server misbehaving` | DNS cannot egress (SNAT missing) | Same as above |
| `Waiting for time sync` deadlock on `talos_cluster_health` | NTP unreachable due to SNAT loss | Same as above — SNAT must be healed before etcd can sync |

> **Reference:** [ADR 003 — SDN SNAT runtime drift](./adr/003-sdn-snat-runtime-drift.md) for single-node limitation and multi-node upgrade guide.

---

Next: [Variables →](./variables.md) · [Usage →](./usage.md) · [CI/CD →](./ci-cd.md)
