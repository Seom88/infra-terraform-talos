# 3. SDN SNAT runtime drift after PVE reboot (single-node fix)

* **Status:** Accepted
* **Date:** 2026-08-29
* **Deciders:** infra-terraform-talos maintainers
* **Tags:** proxmox, sdn, pve, talos, networking, snat, bpg-proxmox, drift

## Context

`modules/proxmox/network.tf` creates the Talos SDN network:

```hcl
proxmox_sdn_zone_simple (talosvn) -> proxmox_sdn_vnet (prod) -> proxmox_sdn_subnet (10.10.0.0/24, snat=true) -> proxmox_sdn_applier (PUT /cluster/sdn)
```

The VNet id `prod` is the Linux bridge name on the PVE node and must match `var.network_bridge`. `proxmox_sdn_applier` performs the actual `PUT /cluster/sdn` so the bridge exists before VM creation.

After a PVE host reboot (`pve01`):

* `/etc/pve/sdn/subnets.cfg` still contains `subnet: talosvn-10.10.0.0-24 vnet prod gateway 10.10.0.1 snat 1`.
* `/etc/network/interfaces.d/sdn` still contains `version:78 auto prod` + `post-up iptables -t nat -A POSTROUTING -s '10.10.0.0/24' -o vmbr0 -j SNAT --to-source 192.168.2.201`.
* But the **runtime** is lost: `iptables -t nat -L POSTROUTING` shows no `MASQUERADE` for `10.10.0.0/24`, bridge `prod` is absent until SDN is re-applied.

Result: VMs (`10.10.0.12` etc.) cannot reach `1.1.1.1:53`:

```
read udp 10.10.0.12:xxxxx->1.1.1.1:53: i/o timeout
lookup time.cloudflare.com on 127.0.0.53:53 server misbehaving
waiting for etcd to be healthy: service "etcd" not in expected state "Running": current state [Waiting] Waiting for time sync
```

`data.talos_cluster_health` (`modules/proxmox/main.tf:223`, `read = "10m"`, `depends_on = [module.talos, time_sleep.post_bootstrap]`) blocks `terraform apply` waiting for `time sync`, creating a deadlock — apply cannot finish, but SDN is never healed because `bpg/proxmox` `proxmox_sdn_applier` (`v0.111.1`, `EXPERIMENTAL`) only triggers on config diff (`replace_triggered_by`), not on runtime drift.

Manual workaround verified on `pve01`:

```bash
ssh root@pve01 'pvesh set /cluster/sdn 2>/dev/null || ifreload -a'
# or equivalently: terraform -chdir=environments/proxmox/prod apply -replace="module.proxmox.proxmox_sdn_applier.this"
```

Works, but requires operator intervention after every reboot and breaks `just tf-apply` / CI.

Related: `environments/proxmox/prod/provider.tf` already uses `var.ssh_username` (default `root`) and `var.ssh_node_address` (`pve01` in `terraform.tfvars`) for the Proxmox provider `ssh {}` block; the SDN fix must reuse the same vars instead of hardcoding `root@pve01`.

## Decision

Add `terraform_data.sdn_ensure_applied` in `modules/proxmox/network.tf` that **installs a boot-time systemd service** on the PVE node:

* **Resource:** `terraform_data.sdn_ensure_applied`
  * `input = "${var.ssh_username}@${coalesce(var.ssh_node_address, var.node_name)}"` — parametrized, no hardcoded `root@pve01`; destroy provisioner uses `${self.input}` because Terraform forbids `var.*` in `when = destroy`.
  * `triggers_replace = [proxmox_sdn_subnet.this.id]` — stable (no `timestamp()`), recreates only when subnet changes.
  * `depends_on = [proxmox_sdn_applier.this]`.

* **Create provisioner (`local-exec`):**
  ```bash
  ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes ${var.ssh_username}@${coalesce(var.ssh_node_address, var.node_name)} 'cat > /etc/systemd/system/pve-sdn-ensure.service <<EOF
  [Unit]
  Description=Ensure Proxmox SDN is applied (heal runtime drift after reboot)
  After=network.target pve-cluster.service
  Wants=network.target pve-cluster.service
  [Service]
  Type=oneshot
  ExecStart=/bin/sh -c "pvesh set /cluster/sdn 2>/dev/null || ifreload -a"
  RemainAfterExit=yes
  [Install]
  WantedBy=multi-user.target
  EOF
  systemctl daemon-reload
  systemctl enable --now pve-sdn-ensure.service
  pvesh set /cluster/sdn 2>/dev/null || ifreload -a
  '
  ```

* **Destroy provisioner (`when = destroy`):**
  ```bash
  ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes ${self.input} 'systemctl disable --now pve-sdn-ensure.service 2>/dev/null; rm -f /etc/systemd/system/pve-sdn-ensure.service; systemctl daemon-reload 2>/dev/null'
  ```

* **Variables:** Added to `modules/proxmox/variables.tf`:
  ```hcl
  variable "ssh_username" { default = "root" }
  variable "ssh_node_address" { type = string default = null } # coalesce to var.node_name
  ```
  Forwarded in `environments/proxmox/prod/main.tf` (`ssh_username = var.ssh_username`, `ssh_node_address = var.ssh_node_address`). `environments/proxmox/prod/variables.tf` already defined them; `terraform.tfvars` sets `ssh_node_address = "pve01"`.

* **In-code limitation comment** left in `network.tf` header (authoritative, visible in review):
  ```
  # LIMITATION: single-node only — zone.nodes=[var.node_name] and service targets
  # only ${var.ssh_username}@${coalesce(var.ssh_node_address, var.node_name)}. Multi-node
  # needs zone.nodes=distinct([...proxmox_node]) and for_each on this resource.
  ```

* **Health check unchanged:** `data.talos_cluster_health` checks all 3 CPs (`[for node in var.nodes_cp : node.ip]` → `10.10.0.11/.12/.13`), `depends_on = [module.talos, time_sleep.post_bootstrap]` (no coupling to the SDN resource).

## Consequences

### Positive

* Reboot-safe: `pve-sdn-ensure.service` heals `prod` + `MASQUERADE 10.10.0.0/24` on every boot without operator.
* Idempotent: `triggers_replace` only on subnet id; `terraform apply` is `No changes` when healthy (`Read complete after 0s/1s`).
* Parametrized: reuses `var.ssh_username` / `var.ssh_node_address` / `var.node_name` — works for `dev` / `prod` with different hosts.
* Clean lifecycle: `terraform destroy` removes the service (`disable --now` + `rm` + `daemon-reload`).
* Fixes `Waiting for time sync` deadlock without workarounds.

### Negative / Limitations

* **Single-node only** — `proxmox_sdn_zone_simple.nodes = [var.node_name]` and the service is installed on one host. With 2+ PVE nodes, `pve02` reboot would still lose its runtime. Documented here and in-code; upgrade path is `for_each` (see Restore Guide).
* `local-exec` over SSH requires `StrictHostKeyChecking=accept-new` + `BatchMode=yes` and that the runner has `ssh` + key/agent to `root@<node>`.
* `terraform_data` `input` change updates in-place (`Plan: 1 to change`); changing `ssh_username`/`ssh_node_address` updates state but does not re-run the create provisioner unless `triggers_replace` includes it — follow Restore Guide for clean rotation.
* `bpg/proxmox` `sdn_applier` is `EXPERIMENTAL` — runtime drift healing is delegated to the service, not the provider.

## Alternatives Considered

1. **Cron `@reboot` on PVE host:** Works but unmanaged by Terraform, not versioned, no destroy cleanup — rejected.
2. **`timestamp()` in `triggers_replace`:** Forces replacement every apply but re-runs SSH on every `just tf-apply` even when healthy — noisy; replaced by stable `subnet.id` + boot-time service — rejected.
3. **PVE hook script (`/etc/pve/hooks`) or `ifupdown2` hook:** PVE-native but not declarative via Terraform — rejected.
4. **Fix in `bpg/proxmox` provider (drift detection):** Upstream would need to detect runtime vs config drift; `sdn_applier` is `EXPERIMENTAL` and only diff-triggered — not available now. Chosen: local service as workaround.

## Restore Guide — Multi-node upgrade

> Run when adding `pve02`/`pve03` or when `var.nodes_cp[].proxmox_node` becomes heterogeneous.

1. **Derive the node set** in `modules/proxmox/network.tf` (or `locals.tf`):
   ```hcl
   locals {
     sdn_nodes = distinct(concat(
       [var.node_name],
       [for n in var.nodes_cp : n.proxmox_node],
       [for n in var.nodes_worker : n.proxmox_node]
     ))
   }
   ```

2. **Zone:** `proxmox_sdn_zone_simple.this.nodes = local.sdn_nodes` (or `var.pve_nodes` if you prefer explicit).

3. **Resource:** `resource "terraform_data" "sdn_ensure_applied" { for_each = toset(local.sdn_nodes) ... }` with `input = "${var.ssh_username}@${each.key}"` and `command` using `${self.input}` for both create and destroy. Keep `depends_on = [proxmox_sdn_applier.this]`.

4. **Variables:** If PVE SSH addresses differ from `node_name` (e.g. Tailscale FQDN), change `ssh_node_address` to `map(string)` (`{ pve01 = "pve01.lonk-mirfak.ts.net", pve02 = "..." }`) and use `lookup(var.ssh_node_address_map, each.key, each.key)`.

5. **Verify:**
   ```bash
   terraform -chdir=environments/proxmox/prod plan  # should show for_each expansion
   just tf-apply
   ssh root@pve01 'systemctl status pve-sdn-ensure.service; iptables -t nat -L POSTROUTING -n | grep MASQUERADE'
   ssh root@pve02 'systemctl status pve-sdn-ensure.service; iptables -t nat -L POSTROUTING -n | grep MASQUERADE'
   ```

6. **Remove limitation comment** in `network.tf` and update this ADR status to `Superseded by ...`.

## References

* `modules/proxmox/network.tf:45-87` — zone/vnet/subnet/applier + `terraform_data.sdn_ensure_applied` with `self.input` destroy fix.
* `modules/proxmox/variables.tf` — `ssh_username`, `ssh_node_address` (coalesce to `node_name`), `node_name`, `network_bridge`, `sdn_zone`.
* `environments/proxmox/prod/provider.tf:51-58` — `provider "proxmox" ssh { username = var.ssh_username, node { name = var.node_name, address = var.ssh_node_address } }`.
* `environments/proxmox/prod/terraform.tfvars:3,5` — `ssh_node_address = "pve01"`, `node_name = "pve01"`.
* `modules/proxmox/main.tf:223` — `data.talos_cluster_health` (`count = var.enable_health_check ? 1 : 0`, `control_plane_nodes = [for node in var.nodes_cp : node.ip]`).
* `CHANGELOG.md` `[Unreleased] Fixed: SDN SNAT runtime drift...` — service `pve-sdn-ensure.service` (`pvesh set /cluster/sdn || ifreload -a`).
* `bpg/proxmox` `v0.111.1` `proxmox_sdn_applier` — `EXPERIMENTAL`, `replace_triggered_by` only.
* `terraform_data` destroy limitation: `References to other resources during the destroy phase can cause dependency cycles` — must use `self.*`.

## TODO

* [ ] When adding a second PVE node, run Restore Guide and remove single-node limitation.
* [ ] Verify `terraform fmt -check -recursive` and `terraform validate` after multi-node change.
* [ ] After multi-node, test reboot of each node independently and verify `iptables -t nat -L POSTROUTING` contains `MASQUERADE` for `10.10.0.0/24`.

---

*ADR 003 follows MADR 2.3.0 structure, matching ADR 001/002 formatting.*
*Provenance: PVE reboot 2026-08-29 — `iptables MASQUERADE` missing, `10.10.0.12 -> 1.1.1.1:53 i/o timeout`, `Waiting for time sync` deadlock, `just tf-apply` hang at `talos_cluster_health Still reading...`.*
*Status Accepted on 2026-08-29 — single-node workaround until multi-node expansion.*
*Review trigger: Adding a second PVE node to the SDN zone.*
