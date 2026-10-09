# Operations

> What destroys the cluster, what causes a rolling reboot, what's safe — and how to upgrade Talos in place.

[← Back to README](../README.md) · [Variables →](./variables.md) · [Platform →](./platform.md)

Some `terraform.tfvars` values make Terraform **destroy and recreate the VMs** instead of updating them in place. A recreated control plane node loses its etcd data; if more than one node is replaced, the cluster loses quorum — the cluster comes back empty, and the platform layer is re-provisioned on the next single `terraform apply` (ArgoCD via `module.platform`, Longhorn via the GitOps repo wave-0 app).

> **Rule of thumb**: `terraform apply` provisions and updates *configuration* and now also drives **rolling Talos upgrades** via `talos_machine.image` (see [Upgrading Talos](#upgrading-talos) below). Only bootstrap image changes and destructive `tfvars` keys still force VM recreation.

## 🔴 Destroys the cluster (VM destroy + recreate)

| tfvars key | What happens |
|------------|--------------|
| `datastore_iso`, `nodes_cp[].datastore` / `nodes_worker[].datastore` | Disks recreated on the new datastore |
| `node_name`, `nodes_cp[].proxmox_node` | Proxmox doesn't migrate VMs between nodes — destroy + create |
| `nodes_cp[].disk_size` / `nodes_worker[].disk_size` (decrease) | Disks can't shrink — destroy + create |
| Removing a node from `nodes_cp` / `nodes_worker` | That VM is destroyed |
| `env_name` | Different resource namespace → full recreate |

## 🟡 Outage without data loss (rolling upgrade / reboot)

| tfvars key | What happens |
|------------|--------------|
| `talos_version` | Bumping the version triggers a **sequential rolling upgrade** via `talos_machine.image` (pull → install → reboot, one node at a time with `-parallelism=1` to protect etcd quorum). No VM recreation, no etcd wipe. `drain_on_upgrade = false`. A fresh `terraform destroy` + `apply` or manually tainting `proxmox_download_file.talos_image` still pulls a new bootstrap image |
| `modules/talos-image/variables.tf` `extensions` (editing system extensions) | New schematic ID changes the `urls` data `installer`/`disk_image` → same rolling upgrade path as `talos_version`. The bootstrap disk (`proxmox_download_file.talos_image`) ignores `url` changes (`lifecycle { ignore_changes = [url] }`), so etcd is preserved |
| `network_bridge`, `sdn_zone`, `network_cidr`, `network_mtu`, `network_snat` | SDN config re-pushed, VMs reboot |
| `gateway` | Machine config re-pushed; cluster endpoint (direct per-node IPs) changes |
| `kubernetes_version` | Machine config re-pushed (rolling kubelet update) |

> **Note**: `proxmox_download_file.talos_image` uses a shared `file_name` (`talos-nocloud-amd64-secureboot.img`) without `env`/`version` suffix and `lifecycle { ignore_changes = [url] }`; Talos upgrades are handled via `talos_machine.image` with sequential rolling reboots. `justfile`'s `tf-apply` runs with `-parallelism=10` for fast bootstrap; use `tf-apply-upgrade` (`-parallelism=1`) for sequential upgrades.

## 🟢 Safe to change

`endpoint`, `api_token`, `ssh_username`, `ssh_node_address`, `insecure`, `nodes_cp[].allow_scheduling`.

> Tailscale node extension is disabled ([ADR 001](./adr/001-remove-tailscale-extension.md)) — uncomment variables in `variables.tf` and add `siderolabs/tailscale` to `modules/talos-image/variables.tf` `extensions` to re-enable.

## Upgrading Talos

Bumping `talos_version` and running `just tf-apply-upgrade` (or `just tf-apply -parallelism=1`) performs a sequential in-place upgrade via `talos_machine.image` (control planes first, then workers) with `-parallelism=1` to protect etcd quorum. The installer image comes from the Image Factory `urls` data source: `factory.talos.dev/nocloud-installer-secureboot/...` (Proxmox) or the plain `nocloud-installer/...` flavor for libvirt when `secureboot = false`. `drain_on_upgrade = false` (revisit when dedicated workers carry workloads). Bump the pin in `environments/<provider>/<env>/terraform.tfvars` (current default `1.14.1`), then apply.

```bash
# Example: bump talos_version in terraform.tfvars (or variables.tf default), then:
just provider=proxmox env=prod tf-apply-upgrade
# or
just provider=libvirt env=dev tf-apply-upgrade
```

**Details:**

- `talos_machine.control_plane` / `talos_machine.worker` set `image = local.installer_image` (from the Image Factory `urls` data source via `modules/talos-image`).
- `drain_on_upgrade` is parameterized (`bool`, default `false`, platform-aware — `false` for prod with Longhorn, opt-in `true` for dev).
- `time_sleep.post_bootstrap` is `10s`; `talos_cluster_health` has `read = "10m"` and blocks until kube-apiserver, etcd, and all nodes are Ready.
- Cold bootstrap (`terraform destroy` + `apply`) uses `-parallelism=10` (fast ~8 min); upgrades use `-parallelism=1` (safe quorum).

### Metrics Server (Option 2)

`kubectl top` works via kubelet certificate rotation: `KubeletConfig rotate-server-certificates=true` on all nodes + `kubelet-serving-cert-approver` and `metrics-server` external manifests on controlplanes only (`modules/talos-cluster/main.tf`). Verify with `kubectl top nodes`.

### CPU affinity lives outside CI

`cpu.affinity` on `proxmox_virtual_environment_vm` requires `root@pam`; CI applies with an API token, so the API silently drops the value. `terraform.tfvars` stays the source of truth (`cpu_affinity`, `cpu_units` per node), and both VM resources set `lifecycle { ignore_changes = [cpu[0].affinity] }` so token-based plans never fight the privileged value. In prod the control-plane pin (`cpu_units = 200`, `cpu_affinity = "2-5,8-11"`) stays active while the worker pin is commented out (workers float until contention says otherwise).

Two-step flow:

```bash
just provider=proxmox env=prod tf-apply        # converges everything except affinity
just provider=proxmox env=prod affinity-sync   # root over SSH: qm set affinity/cpuunits per tfvars hostname, then prints qm config proof
```

Drift contract: if `qm config` disagrees with `tfvars`, `tfvars` wins — re-run `affinity-sync`. Never hand-edit affinity on the host; never add a second source for it.

### Swap verification

Each node provisions a fixed 4 GiB swap partition on its dedicated 5 GiB disk (`grow = false`). After rollout:

```bash
talosctl -n <NODE> get disks -o yaml
talosctl -n <NODE> get swap
talosctl -n <NODE> get zswapstatus
talosctl -n <NODE> cgroups --preset=swap
```

### Cilium Operations & Troubleshooting

#### Health checks

```bash
# Cilium agents and operator
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system get pods -l io.cilium/app=operator-generic  # or name=cilium-operator

# Cilium status (per-node agent health, KubePrism, kube-proxy replacement)
kubectl -n kube-system exec ds/cilium -- cilium status --verbose
# or via cilium CLI if installed
cilium status --wait

# Hubble flows (requires hubble relay)
kubectl -n kube-system get pods -l k8s-app=hubble-relay
hubble observe --follow --namespace default
hubble observe --verdict DROPPED  # dropped flows only

# Full connectivity suite (deploy then clean up)
cilium connectivity test
```

Expected: `cilium status` shows `Kubernetes: Ok`, `KubeProxyReplacement: Strict`, `Cilium: Ok`, Hubble `Ok`. All `cilium-*` pods `Running` and `Ready`.

#### NotReady diagnosis (CNI not Ready)

Nodes stay `NotReady` until a CNI is present — `terraform_data.wait_nodes` (`kubectl wait --for=condition=Ready`) intentionally runs **after** `helm_release.cilium` for this reason.

If nodes remain `NotReady`:

```bash
kubectl get nodes
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system logs ds/cilium --tail=100
kubectl -n kube-system logs deploy/cilium-operator --tail=100
kubectl get events --sort-by=.lastTimestamp | tail -n 30
```

Common causes: Cilium Helm release still progressing (`wait=true` timeout `1800s` — check `helm -n kube-system status cilium`), CRDs missing (gateway_api must precede cilium), or Talos multi-doc CNI patch not applied (`KubeFlannelCNIConfig` delete + `KubeProxyConfig` `enabled: false`, see `modules/talos-cluster/main.tf:26-37` and [Networking: Cilium](./networking.md#cilium-cni-ebpf-data-plane)).

#### Operator HA (prod 2 replicas)

`var.cilium_operator_replicas` maps to `operator.replicas` via Helm `set`. Leader election ensures a single active operator.

- **Dev / single-node**: `1` (default, RAM-constrained).
- **Prod (single control-plane)**: `2` — tolerates one operator pod loss without cold start. No need for `3`; two with leader election is sufficient.

```bash
kubectl -n kube-system get deploy cilium-operator -o jsonpath='{.spec.replicas}{"\n"}'
kubectl -n kube-system get pods -l io.cilium/app=operator-generic
```

Renovate tracks `cilium_version` (`1.20.2`) weekly (Mon 05:00 Europe/Madrid, `baseBranch: dev`, automerge patch/minor).

#### Hubble relay / UI and silent drops

| Port | Component | Purpose |
|------|-----------|---------|
| `9962` | `prometheus` (cilium-agent) | Agent metrics |
| `9963` | `operator.prometheus` | Operator metrics |
| `9964` | `envoy.prometheus` | Envoy/Gateway API metrics |
| `9965` | `hubble.metrics` | Hubble metrics (`enableOpenMetrics`) |
| `9966` | `hubble.relay.prometheus` | Hubble relay metrics |
| (relay) | `hubble-relay` | `hubble observe` backend (port-forward `4245` if needed) |
| (UI) | `hubble-ui` | Visual flow browser (port-forward `12000` if needed) |

```bash
# Port-forward Hubble UI / relay for local debugging
kubectl -n kube-system port-forward svc/hubble-ui 12000:80
kubectl -n kube-system port-forward svc/hubble-relay 4245:80
# then open http://localhost:12000 and run `hubble observe --server localhost:4245`
```

**Silent drops (policy verdict):**

```bash
# Flows dropped by policy — look at policy verdict and labels
hubble observe --verdict DROPPED --output json | jq
hubble observe --verdict DROPPED --pod default/<pod> --output table

# Check which CiliumNetworkPolicy is in effect (infra-owned, via ArgoCD)
kubectl get ciliumnetworkpolicies.cilium.io -A
kubectl -n argocd get ciliumnetworkpolicies.cilium.io
kubectl describe ciliumnetworkpolicy -n <ns> <name>

# Agent policy state
kubectl -n kube-system exec ds/cilium -- cilium policy get
```

If `kubectl port-forward` / `exec` / `logs` fails with `RST` or hangs, verify `socketLB.enabled=true` with `hostNamespaceOnly=true` in `modules/platform/values/cilium/values.yaml` — Cilium is configured this way so socket LB is restricted to the host netns and does not intercept `127.0.0.1` connect in pod netns (required because Cilium 1.20 defaults `socketLB.enabled=false`; see [Networking: Cilium](./networking.md#cilium-cni-ebpf-data-plane)).

## Notes

- **Validation:** 57 blocks cover semver, CIDR, IP, `^(dev|prod)$` — invalid `tfvars` fail at `terraform validate` before any VM mutation. See [Variables](./variables.md) and [CI/CD](./ci-cd.md).
- **State:** Single state file at `environments/<provider>/<env>/terraform.tfstate` (infra + platform). Prod is S3-compatible (`terraform-homelab`), dev is local. See [Platform](./platform.md#state).
- **Networking reboot drift:** After PVE reboot, `pve-sdn-ensure.service` heals the SDN bridge + MASQUERADE automatically. See [Networking](./networking.md) and [ADR 003](./adr/003-sdn-snat-runtime-drift.md).

---

Next: [Platform →](./platform.md) · [Usage →](./usage.md) · [Networking →](./networking.md)
