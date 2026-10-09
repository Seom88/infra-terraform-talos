# Platform

> Composable ArgoCD module — one `terraform apply` deploys both infra and platform, with migration guides for existing clusters.

[← Back to README](../README.md) · [Operations →](./operations.md) · [Usage →](./usage.md)

> **Two-repo contract:** This repo ships the **substrate + ArgoCD** only. All platform workloads — Longhorn (wave-0, CSI-gated), Vault, SeaweedFS, monitoring, Tailscale ingress — are declared in the companion repo [gitops-platform](https://github.com/Seom88/gitops-platform) (`platform/` + `gitops/templates/apps/` `00-longhorn` → `04-tailscale`). For _why_ this split exists, see [Why This Exists](../README.md#why-this-exists) and [Decisions: composable ArgoCD](./decisions.md#6-argocd-vs-fluxcd).

## Overview

The **platform layer** is a composable module (`modules/platform`) called from each environment root (`environments/<provider>/<env>`). It installs the **platform** on top of the cluster in the same state file and same `terraform apply`:

- **Gateway API CRDs** (`gateway-api-crds`) — CRDs for Gateway API (via `helm_release.gateway_api` `christianhuth/gateway-api-crds` `1.2.4`, `standard` channel).
- **Cilium** (`cilium`) — CNI Without kube-proxy + Gateway API (via `helm_release.cilium` `cilium/cilium` `1.20.2`, values `modules/platform/values/cilium/values.yaml`).
- **ArgoCD** (`argocd`) — GitOps engine (via `helm_release.argocd` in `modules/platform`).

Longhorn is **no longer** installed here: it is a platform app of the GitOps repo (`gitops-platform`, `platform/longhorn`, wave 0, gated by a CSI readiness Job) — see [Decisions: Talos Longhorn prerequisites](./decisions.md#1-talos-linux-vs-kubeadm) and [Decisions: wave-0 CSI gate](./decisions.md#6-argocd-vs-fluxcd). The Longhorn node prerequisites still live in this repo at cluster level: dynamic `UserVolumeConfig` per `disks[].name` (`/var/mnt/<name>`, no kubelet `extraMounts`) and the `iscsi-tools` / `util-linux-tools` system extensions (`modules/talos-image`). See [ADR 005](./adr/005-longhorn-storage-contract.md).

See `modules/platform/README.md` for the module's own README.

## Setup flow (composed)

1. `just provider=proxmox env=prod tf-apply` — provisions the cluster (VMs, Talos bootstrap) and then the platform in DAG order `gateway_api` → `cilium` → `wait_nodes` → `argocd`. The infra health gate (`talos_cluster_health`) blocks until kube-apiserver, etcd, and all nodes are bootstrapped; `helm_release.gateway_api` installs Gateway API CRDs (`1.2.4`, standard), `helm_release.cilium` installs Cilium `1.20.2` (Without kube-proxy + Gateway API, KubePrism `localhost:7445`), then `module.platform.terraform_data.wait_nodes` waits for `Ready` nodes (CNI must be present), finally `helm_release.argocd`. The DAG `gateway_api → cilium → wait_nodes → argocd` ensures CRDs exist before Cilium and nodes become `Ready` only after the CNI is present.
2. `just provider=proxmox env=prod setup-cli` — regenerates `secrets/proxmox/prod/kubeconfig.yaml` and merges it into the local CLI configs (still useful for out-of-band debugging).
3. GitOps repo bootstrap — ArgoCD syncs the applications from the GitOps repository; Longhorn is deployed as a wave-0 app (with CSI readiness gate) during this step.

Each environment configures the `helm` provider against `secrets/<provider>/<env>/kubeconfig.yaml` (see `environments/<provider>/<env>/provider.tf`). The module accepts `kubeconfig_path = abspath("${path.root}/../../../secrets/<provider>/<env>/kubeconfig.yaml")` and re-triggers the node gate when the kubeconfig hash changes.

**Destroy:** a single `just provider=proxmox env=prod tf-destroy` tears down both infra and platform (one state). To remove only the platform release:

```bash
terraform -chdir=environments/proxmox/prod destroy -target=module.platform.helm_release.argocd
```

## Module details

### What it does

1. **Gateway API CRDs** (`helm_release.gateway_api`) — installs `christianhuth/gateway-api-crds` `1.2.4` (`standard` channel, `experimental` disabled) from `https://christianhuth.github.io/helm-charts` into `kube-system`. Helm-managed CRDs; must be present before Cilium (`gatewayAPI.enabled=true`).
2. **Cilium** (`helm_release.cilium`) — installs `cilium/cilium` `1.20.2` from `https://helm.cilium.io/` into `kube-system` via Helm (not `inlineManifests`) to avoid manifest/secrets bloat in `tfstate` and keep the Helm provider flow. Values from `modules/platform/values/cilium/values.yaml` — Sidero [Deploying Cilium](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium#cli-install) "Without kube-proxy + Gateway API": `ipam.mode=kubernetes`, `kubeProxyReplacement=true`, `k8sServiceHost=localhost` `k8sServicePort=7445` (KubePrism), `cgroup.autoMount.enabled=false` `hostRoot=/sys/fs/cgroup`, `securityContext` Talos capabilities, `gatewayAPI.enabled/enableAlpn/enableAppProtocol=true`; `operator.replicas` via `var.cilium_operator_replicas`. `depends_on = [helm_release.gateway_api]`.
3. **Node readiness gate** (`terraform_data.wait_nodes`) — waits for all nodes to be `Ready` via `kubectl wait`. Layer 2; Layer 1 is the `talos_cluster_health` gate in the infra module (`modules/proxmox` / `modules/libvirt`). `depends_on = [helm_release.cilium]` — CNI must be present for nodes to become `Ready`; this ordering ensures the readiness gate runs only after Cilium is installed.
4. **ArgoCD** (`helm_release.argocd`) — installs the `argo-cd` chart from `https://argoproj.github.io/argo-helm`. `depends_on = [terraform_data.wait_nodes]` which transitively implies `gateway_api` + `cilium`.

### ArgoCD gateway path + sync-wave policy

| Topic | Decision |
|-------|----------|
| `/argocd` strip mode | ArgoCD is served at `/argocd` via the cluster gateway (path stripped to `argocd-server:80`); `server.insecure=true` for the HTTP proxy (`modules/platform/values/argocd/values.yaml`) |
| Sync-wave health gate | Custom `health.lua` for `argoproj.io/Application`: default `healthy` policy requires Synced + Healthy; opt out per app with label/annotation `wave-policy: sync-only` (Synced is enough) |
| ServiceMonitors | All Cilium `serviceMonitor.enabled=false` until monitoring is synced in the GitOps repo (`modules/platform/values/cilium/values.yaml`) |

### Inputs

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `kubeconfig_path` | string | — (required) | Path to kubeconfig file. Re-triggers `wait_nodes` via `filesha256` when it changes. If file missing, trigger is `kubeconfig-missing`. |
| `cilium_version` | string | `1.20.2` | Exact Cilium chart version (`cilium/cilium`). |
| `cilium_namespace` | string | `kube-system` | Namespace for Cilium. |
| `cilium_values_file` | string | `""` → `values/cilium/values.yaml` | Custom Cilium Helm values file path (Sidero Without kube-proxy + Gateway API). |
| `cilium_operator_replicas` | number | `1` | Cilium operator replicas (`1..3`, leader election; `1` for dev/single-node, `2` for single-CP prod). Sets `operator.replicas` via Helm `set`. |
| `gateway_api_crds_version` | string | `1.2.4` | Gateway API CRDs chart version (`christianhuth/gateway-api-crds`). |
| `gateway_api_version` | string | `1.2.4` | Alias for `gateway_api_crds_version` (same chart version). |
| `gateway_api_crds_namespace` | string | `kube-system` | Namespace for Gateway API CRDs release (CRDs are cluster-scoped; Helm still needs a namespace). |
| `gateway_api_channel` | string | `standard` | Gateway API channel: `standard` (stable) or `experimental`. Maps to `standard.enabled` / `experimental.enabled`. |
| `argocd_version` | string | `10.9.2` | Exact ArgoCD chart version. |
| `argocd_namespace` | string | `argocd` | Namespace for ArgoCD. |
| `argocd_values_file` | string | `""` → `values/argocd/values.yaml` | Custom Helm values file path. |

> Cilium values file is `modules/platform/values/cilium/values.yaml` (Sidero pattern Without kube-proxy + Gateway API: `ipam=kubernetes`, `kubeProxyReplacement`, `k8sServiceHost=localhost:7445`, `cgroup.autoMount=false`, `gatewayAPI.enabled`, caps). Prod uses this lean file as-is; dev layers `values-dev.yaml` on top via `cilium_values_file` (debug/observability overlay — Hubble etc.).

### Outputs

- `argocd_namespace`, `argocd_version`, `argocd_release_name`

### Kubeconfig handling

The helm provider's `config_path` must point to a file that exists at apply time. The file is at `secrets/<provider>/<env>/kubeconfig.yaml` and is materialized by `just gen-secrets` (`terraform output -raw kubeconfig > secrets/.../kubeconfig.yaml`). The `talos_cluster_health` → `gateway_api` → `cilium` → `wait_nodes` chain ensures CRDs + CNI are ready before ArgoCD (nodes `Ready` implies CNI).

## Migrating an existing cluster

If the cluster already has ArgoCD installed (for example, via the `init-infra.sh` script from the GitOps repo), adopt the existing release into the Terraform state with `terraform import`:

```bash
terraform -chdir=environments/proxmox/prod import 'module.platform.helm_release.argocd' argocd/argocd
```

For legacy `platform/` states, see [CHANGELOG.md](../CHANGELOG.md) (2.0.0) and `modules/platform/README.md` for `terraform state mv` from the standalone root into the composed environment state:

```bash
# From repo root, after updating code:
terraform -chdir=environments/proxmox/prod init -reconfigure
terraform -chdir=platform init -reconfigure -backend-config="path=environments/proxmox/prod/terraform.tfstate"

# Move the Helm release into the composed state:
terraform -chdir=environments/proxmox/prod state mv \
  'helm_release.argocd' \
  'module.platform.helm_release.argocd'

# Move the wait_nodes gate if you want history preserved:
terraform -chdir=environments/proxmox/prod state mv \
  'terraform_data.wait_nodes' \
  'module.platform.terraform_data.wait_nodes'

# Verify and remove deprecated platform state:
terraform -chdir=environments/proxmox/prod plan
rm -rf platform/environments
```

Replace `proxmox/prod` with your `provider/env`.

### Migrating Longhorn to the GitOps repo (legacy)

Longhorn is no longer managed here. If you still have a legacy `platform/` state that contains `helm_release.longhorn`:

```bash
# 1) In the secured repo: push the changes (platform/longhorn + gitops/values) and
#    wait until the longhorn ArgoCD app is Healthy (CSI gate Job completed).
# 2) Only then, in the legacy root, remove the resources from the TF state so the next
#    apply does NOT destroy them:
terraform -chdir=platform state rm helm_release.longhorn kubernetes_namespace_v1.longhorn_system kubernetes_manifest.longhorn_prod_storageclass terraform_data.csi_waiter
# 3) Apply the reduced platform layer (ArgoCD only) in the composed model:
just provider=proxmox env=prod tf-apply
# Do NOT run terraform destroy on helm_release.longhorn: it would delete the volumes.
```

## State

Platform is now composed in each environment root — single state at `environments/<provider>/<env>/terraform.tfstate` (covers both infra `module.proxmox`/`module.libvirt` and `module.platform`). Prod state is on S3-compatible storage (bucket `terraform-homelab`); dev state is local (intentional, no lock — see C1). CI no longer uses `tfstate-*` artifacts.

> **Migration note:** legacy locations `platform/terraform.tfstate`, `platform/environments/prod/platform-terraform.tfstate`, `platform/environments/<env>/platform-terraform.tfstate`, and `platform/environments/<provider>/<env>/terraform.tfstate` are superseded by the composed model. Keep old files on disk for manual `terraform state mv` into `environments/<provider>/<env>/module.platform.*` (see [CHANGELOG.md](../CHANGELOG.md) 2.0.0), but new `just tf-apply` and CI use the single environment state.

## Deprecated `just` tasks

`tf-platform-*` tasks are kept for backward compatibility and now delegate to `tf-apply`/`tf-plan`/`tf-init` with a deprecation warning:

| Task | Description |
|------|-------------|
| `tf-platform-init` | Deprecated → delegates to `tf-init` |
| `tf-platform-plan` | Deprecated → delegates to `tf-plan` |
| `tf-platform-apply` | Deprecated → delegates to `tf-apply` |
| `tf-platform-destroy` | Deprecated → prints destroy guidance (`tf-destroy` or `terraform destroy -target=module.platform.helm_release.argocd`) |

The header of the `justfile` documents the composed model (`platform/` root deprecated — see `CHANGELOG.md`).

---

Next: [Usage →](./usage.md) · [Networking →](./networking.md) · [CI/CD →](./ci-cd.md)
