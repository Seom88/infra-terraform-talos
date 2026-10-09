# Usage

> Requirements, outputs, how to access the cluster, and every `just` task — the day-to-day workflow.

[← Back to README](../README.md) · [Architecture →](./architecture.md) · [Networking →](./networking.md)

## Requirements

- **Proxmox path**: Proxmox VE 9.x with API access
- **Network access (Proxmox SDN)**: the machine running `terraform apply` (laptop or CI) must be able to reach the cluster subnet `10.10.0.0/24`. The `talosvn` SDN VNet is isolated — VMs get outbound internet via SNAT but nothing from outside reaches them directly. For `prod`, expose the subnet through a Tailscale subnet router (see [Access → Proxmox](#proxmox) and [Networking](./networking.md#tailscale-subnet-routing-both-providers))
- **Libvirt path**: Linux host with libvirt + KVM and `qemu:///system` accessible
- Terraform >= 1.11
- Talos Image Factory schematic ID (read via `just get-schematic-id`, sourced from `terraform output -raw schematic_id`)

See [Networking](./networking.md) for SDN/NAT and Tailscale subnet-routing details.

## Outputs

| Output | Providers | Description |
|--------|-----------|-------------|
| `talosconfig` | both | Talos client configuration for talosctl |
| `kubeconfig` | both | Standard kubeconfig for kubectl (single context via subnet route `10.10.0.0/24`) |
| `machine_configuration_cp` | module | Talos machine config for control plane nodes (used by libvirt cloud-init) |
| `machine_configuration_worker` | module | Talos machine config for worker nodes (used by libvirt cloud-init) |

Secrets are materialized to `secrets/<provider>/<env>/talosconfig.yaml` and `kubeconfig.yaml` via `just gen-secrets` (`.gitignored`).

## Access

Use `provider` and `env` to select the cluster (defaults: `proxmox` / `prod`). API access is via direct per-node IPs (`10.10.0.0/24` via subnet route), health-gated by `talos_cluster_health`. Kubeconfig has a single context via subnet route.

### Proxmox

```bash
# Direct per-node IP (via subnet route 10.10.0.0/24)
talosctl --talosconfig secrets/proxmox/prod/talosconfig.yaml -n 10.10.0.11 version
kubectl --kubeconfig secrets/proxmox/prod/kubeconfig.yaml get nodes
```

### Libvirt

```bash
# Direct per-node IP (via NAT / subnet route)
talosctl --talosconfig secrets/libvirt/dev/talosconfig.yaml -n 10.0.1.11 version
kubectl --kubeconfig secrets/libvirt/dev/kubeconfig.yaml get nodes
```

See [Networking](./networking.md) for reachability troubleshooting.

## `just` tasks

All tasks run from the repo root. `provider` (`proxmox` | `libvirt`) and `env` (`prod` | `dev`) select the environment (defaults: `proxmox`/`prod`):

```bash
just tf-apply                              # proxmox/prod (default)
just provider=proxmox env=dev tf-apply     # proxmox/dev
just provider=libvirt env=dev tf-apply     # libvirt/dev
just provider=libvirt env=prod tf-apply    # libvirt/prod
```

| Task | Description |
|------|-------------|
| `tf-fmt` | Format all Terraform files recursively |
| `tf-fmt-check` | Check formatting like CI (fails with diff if not formatted) |
| `tf-validate` | Validate all envs like CI — `init -backend=false` + `validate` for all 4 envs (`proxmox/prod`, `proxmox/dev`, `libvirt/prod`, `libvirt/dev`) + `modules/platform` |
| `tf-ci` | Full CI check locally: `tf-fmt-check` + `tf-validate` |
| `tf-init` | Initialize Terraform with the env backend (local for dev, S3-compatible for prod) |
| `tf-plan` | Plan changes for the active provider/env |
| `tf-apply` | Apply changes (bootstrap or update) — runs with `-parallelism=10` (fast bootstrap, use `tf-apply-upgrade -parallelism=1` for Talos rolling upgrades) |
| `tf-apply-upgrade` | Apply with `-parallelism=1` for sequential Talos rolling upgrades (protects etcd quorum) |
| `tf-destroy` | Tear down the active provider/env (`TF_VAR_enable_health_check=false` so the health gate does not block) |
| `gen-secrets` | Extract talosconfig + kubeconfig from state |
| `setup-cli` | `gen-secrets` + merge into `~/.talos/config` and `~/.kube/config` |
| `status` | Show Talos version, extensions, and cluster members |
| `get-schematic-id` | Read schematic ID from state (`terraform output -raw schematic_id`, canonical set in `modules/talos-image`) |
| `cluster-schematic-id` | Read the active schematic ID from the running cluster |
| `setup-host` | (libvirt) Ensure firewalld NAT for `virbr-talos` — masquerade + forward on zone `libvirt` (idempotent, needs sudo) |
| `affinity-sync` | (proxmox-only, `root`) Apply `cpu_affinity`/`cpu_units` from `terraform.tfvars` via `qm set` (VMIDs resolved by hostname, `qm config` proof) — prod workers are commented out in `tfvars` since 2.3.0, so only the control-plane row is emitted |

### Quick examples

```bash
# Bootstrap proxmox/prod (default env)
just tf-apply
just setup-cli                         # proxmox/prod (default)
just provider=proxmox env=dev setup-cli  # proxmox/dev

# Libvirt
just provider=libvirt tf-apply
just provider=libvirt setup-cli

# Validate everything in 60s (no backend, no creds) — like CI validate
just tf-validate

# Sequential upgrade (protects etcd quorum)
just tf-apply-upgrade
just provider=proxmox env=prod tf-apply-upgrade
```

### Platform (ArgoCD) — composed tasks

Platform (ArgoCD) is a composable module (`modules/platform`) called from each environment root. One `terraform apply` deploys both infra and platform in one state file at `environments/<provider>/<env>/terraform.tfstate`. See [Platform](./platform.md).

`tf-platform-*` tasks are deprecated and delegate to `tf-*` with a warning:

| Task | Description |
|------|-------------|
| `tf-platform-init` | Deprecated → delegates to `tf-init` |
| `tf-platform-plan` | Deprecated → delegates to `tf-plan` |
| `tf-platform-apply` | Deprecated → delegates to `tf-apply` |
| `tf-platform-destroy` | Deprecated → prints destroy guidance (`tf-destroy` or `terraform destroy -target=module.platform.helm_release.argocd`) |

## 60s dry-run validate (no creds)

Like CI `validate` — no backend, no secrets needed:

```bash
just tf-validate
# or manually:
terraform -chdir=environments/proxmox/prod init -backend=false && terraform -chdir=environments/proxmox/prod validate -no-color
```

---

Next: [Variables →](./variables.md) · [Operations →](./operations.md) · [CI/CD →](./ci-cd.md)
