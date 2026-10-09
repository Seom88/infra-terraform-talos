# Decisions — Why This Stack

> This file explains why I chose each core piece — not how it works
> (see [Architecture](./architecture.md), [Networking](./networking.md), [Platform](./platform.md)).

Back to [Why This Exists](../README.md#why-this-exists) · [Architecture](./architecture.md) · [Networking](./networking.md) · [Platform](./platform.md) · [ADRs](./adr/) · [README](../README.md)

| Component | Choice | One-line why |
|---|---|---|
| Hypervisor (prod) | [Proxmox VE](https://www.proxmox.com/) | Open, cost-effective license and `bpg/proxmox` Terraform gives a cloud-like declarative experience (VMs, SDN) |
| Hypervisor (dev) | [libvirt + KVM](https://libvirt.org/) | Local testing before prod and portable to AlmaLinux/Cockpit with desktop advantages, without losing IaC |
| OS | [Talos Linux](https://www.talos.dev/) | Immutable and declarative — versioned, reproducible Kubernetes in a VM via Image Factory schematic |
| Remote access | [Tailscale](https://tailscale.com/kb/1214/subnet-routers) | Subnet routing `10.10.0.0/24` for VM access, tailnet service exposure via GitOps, and CI without exposing the server |
| Storage | [Longhorn](https://longhorn.io/) | Popular, lighter than Ceph, flexible and reliable PVC replication across nodes |
| CNI | [Cilium](https://docs.cilium.io/) 1.20.2 | Pod-to-pod security via NetworkPolicies and microsegmentation |
| GitOps | [ArgoCD](https://argo-cd.readthedocs.io/) | Popular enterprise GitOps with App-of-Apps |

> Each choice below includes the reasoning and a pointer to the relevant files.

---

<!-- Anchors preserve historic URLs; headings are ordered by narrative (Proxmox → libvirt → Talos → Tailscale → Longhorn → Cilium → ArgoCD) — links use anchor IDs, not heading numbers. -->

<a id="2-proxmox-ve-vs-esxi-bare-metal"></a>
## 1. Proxmox VE — open license and cloud-like IaC

I chose Proxmox VE because its open license is cost-effective compared to ESXi
and other enterprise hypervisors. Just as important, its API together with the
`bpg/proxmox` Terraform provider gives an experience much closer to a public
cloud: VMs, SDN zones, VNets and subnets are declared in Terraform instead of
clicked in a UI.

That lets me manage the homelab with the same declarative, versioned workflow
I would use on cloud — one `terraform apply` for networking and machines, with
reusable modules and no manual host setup.

**Evidence:** `modules/proxmox/main.tf` + `modules/proxmox/network.tf` + `environments/proxmox/prod/provider.tf` (`bpg/proxmox`, SDN `talos`/`talosvn` `10.10.0.0/24`).

<a id="3-libvirt-kvm-vs-proxmox-only"></a>
## 2. Libvirt + KVM — local testing and portability

I chose libvirt + KVM as a second provider so I can create machines locally
and test changes before Proxmox prod is affected. It gives a fast, zero-cost
feedback loop for Renovate bumps and Talos upgrades without needing physical
Proxmox hardware.

It also keeps the door open for a future migration to AlmaLinux with Cockpit.
That path would bring the advantages of a real desktop while still provisioning
everything through IaC, with no rework of the Talos bootstrap.

**Evidence:** `modules/libvirt/network.tf` (`virbr-talos` NAT) + `modules/libvirt/vms.tf` + `modules/libvirt/cluster.tf` (same `modules/talos-cluster` as prod).

<a id="1-talos-linux-vs-kubeadm"></a>
## 3. Talos Linux — immutable, declarative Kubernetes

I chose Talos Linux because it is immutable and declarative. Unlike a
traditional distro with SSH and apt drift, Talos lets me provision Kubernetes
in a VM in an easier, fully versioned way: machine configs are generated from
Terraform and the OS image is built via the Image Factory schematic.

Upgrades are atomic — bump the schematic and the Talos/Kubernetes version in
`terraform.tfvars` and roll the cluster with `talos_machine` — with reproducible
rebuilds in minutes.

**Evidence:** `modules/talos-image/` (Image Factory `systemExtensions` via `exact_filters`) + `modules/talos-cluster/main.tf` (`talos_machine`, `talos_cluster`).

<a id="4-tailscale-subnet-routing-vs-per-node-extension"></a>
## 4. Tailscale — subnet routing for VMs, services and CI

I chose Tailscale with subnet routing to access the VMs over `10.10.0.0/24`
without installing an extension on every node. The Proxmox host advertises the
route and clients and CI accept it, giving a single L3 path to the kube API.

That same tailnet makes it easier to expose services via GitOps and supports
CI/CD without exposing the server to the internet — CI joins the tailnet
with `tailscale/github-action` and reaches the cluster directly.

**Evidence:** `modules/proxmox/network.tf` (`10.10.0.0/24` `snat`) + `modules/talos-image/variables.tf` extensions (tailscale disabled, see ADR 001) + `.github/workflows/deploy.yaml` (`tailscale/github-action`).

<a id="5-longhorn-vs-ceph-rook"></a>
## 5. Longhorn — lightweight, reliable PVC replication

I chose Longhorn because it is a popular provisioning solution that, without
being as heavy as Ceph and similar systems, is quite flexible and reliable at
replicating PVCs between nodes. For a 3-node homelab, Ceph/Rook is operationally
heavy (MON/MGR/OSD, crush maps, memory).

Longhorn gives the cluster HA block storage with a simple CSI driver, homogeneous
dual-disk nodes (`/var/mnt/data` via dynamic `UserVolumeConfig`, no kubelet `extraMounts` — see ADR 005),
and a familiar Helm install gated by ArgoCD.

**Evidence:** `modules/talos-cluster/main.tf` (dynamic UVCs) + `modules/proxmox/main.tf` (SCSI data disks) + [ADR 005](./adr/005-longhorn-storage-contract.md).

<a id="7-cilium-inlinemanifest-vs-helm-application"></a>
## 6. Cilium — pod-to-pod security and microsegmentation

I chose Cilium to improve security between pods. It replaces kube-router with
eBPF, enabling NetworkPolicies and microsegmentation, plus Hubble observability,
from day one.

Talos disables the built-in CNI (multi-doc patch: `KubeFlannelCNIConfig` `$patch: delete` + `KubeProxyConfig` `enabled: false` in `modules/talos-cluster/main.tf:26-37`). Cilium is installed via Helm in `modules/platform` (not via Talos `cluster.inlineManifests`) to avoid state bloat and secrets in `tfstate` and keep the Helm provider flow consistent. Values follow the Sidero [Deploying Cilium](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium) "Without kube-proxy + Gateway API" pattern (`ipam=kubernetes`, `kubeProxyReplacement=true`, `k8sServiceHost=localhost:7445` KubePrism, `cgroup.autoMount=false`, `gatewayAPI.enabled=true` in `modules/platform/values/cilium/values.yaml`; prod uses the lean file, dev layers `values-dev.yaml` via `cilium_values_file`). Gateway API CRDs (`christianhuth/gateway-api-crds` `1.2.4` standard) are Helm-installed **before** Cilium (`gateway_api → cilium → wait_nodes → argocd`); this ordering is required because `gatewayAPI.enabled=true` needs CRDs to exist first.

**Evidence:** `modules/talos-cluster/main.tf:26-37` (`KubeFlannelCNIConfig` delete, `KubeProxyConfig` `enabled: false`) + `modules/platform/main.tf` (`helm_release.gateway_api` `1.2.4` → `helm_release.cilium` `1.20.2` → `terraform_data.wait_nodes` → `helm_release.argocd`) + `modules/platform/values/cilium/values.yaml` (Sidero Without kube-proxy + Gateway API) · Sidero [Deploying Cilium](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium).

<a id="6-argocd-vs-fluxcd"></a>
## 7. ArgoCD — popular enterprise GitOps

I chose ArgoCD because it is the popular GitOps option in the enterprise
world. It fits this repo's model: Terraform installs ArgoCD once via
`helm_release.argocd`, then ArgoCD owns everything else through App-of-Apps and
sync-waves.

That gives the project a single source of truth in Git, a rich UI and history, and clean
`terraform destroy` semantics — all without a second manual bootstrap.

**Evidence:** `modules/platform/main.tf` (`helm_release.argocd`) + companion `gitops/templates/apps/*` (`00-longhorn` → `04-tailscale`, sync-waves).

---

### Where decisions surface in docs

| # | Decision | README | Deep dive |
|---|---|---|---|
| 2 | Proxmox VE | [Why This Exists](../README.md#why-this-exists) | [Networking](./networking.md), [Variables](./variables.md) |
| 3 | Libvirt + KVM | [Skills](../README.md#skills-demonstrated) | [Architecture](./architecture.md), [Usage](./usage.md) |
| 1 | Talos Linux | [Why This Exists](../README.md#why-this-exists) | [Architecture](./architecture.md), [Operations](./operations.md) |
| 4 | Tailscale | [Why This Exists](../README.md#why-this-exists) | [Networking](./networking.md) |
| 5 | Longhorn | [Roadmap](../README.md#roadmap--changelog) | [Platform](./platform.md), [Operations](./operations.md) |
| 7 | Cilium | [Roadmap](../README.md#roadmap--changelog) | [Architecture](./architecture.md), [Operations](./operations.md) |
| 6 | ArgoCD | [Why This Exists](../README.md#why-this-exists) | [Platform](./platform.md) |

Back to [Why This Exists](../README.md#why-this-exists) · [Architecture](./architecture.md) · [Networking](./networking.md) · [Platform](./platform.md)
