# 2. Pinned Talos provider to 0.12.0-beta.0

* **Status:** Accepted
* **Date:** 2026-08-28
* **Deciders:** infra-terraform-talos maintainers
* **Tags:** talos, terraform-provider-talos, semver, pre-release, provider-pinning

## Context

`siderolabs/talos` provider `0.11.x` and early `0.12.0` pre-releases exhibit a
deterministic planning bug tracked as
[siderolabs/terraform-provider-talos#352](https://github.com/siderolabs/terraform-provider-talos/issues/352)
— **"inconsistent final plan"** — where `terraform plan` produces a diff that
`terraform apply` cannot converge on:

```
Error: Provider produced inconsistent final plan
When expanding the plan for talos_machine_configuration_apply.* to include
new values learned so far during apply, provider "registry.terraform.io/siderolabs/talos"
produced an invalid new value for <attribute>.
```

The bug surfaces with `talos_machine` / `talos_cluster` resources introduced in
provider `0.12` (replacing `talos_machine_configuration_apply` +
`talos_machine_bootstrap`). `modules/talos-cluster/main.tf` migrated to:

```hcl
resource "talos_machine" "control_plane" { ... }
resource "talos_machine" "worker"        { ... }
resource "talos_cluster" "cluster"       { ... }
```

with `ignore_kubernetes_upgrade_drift = true` and `kubernetes_version` now owned
by `talos_cluster` — the intended upgrade path for Talos 1.13.9 / Kubernetes
1.36. Upgrading required `required_version >= 1.11` (TF 1.15.9 write-only).

Upstream fix status:

*   Bug confirmed on `0.11` / `0.12.0-alpha` cycle; SideroLabs fixed it **only**
    on the `0.12` branch.
*   No stable `0.12.0` released as of `2026-08-28`.
*   Last verified pre-release containing the fix is `0.12.0-beta.0`
    (`2026-06-25`, registry `siderolabs/talos`).
*   Earlier alphas (`alpha.1`–`alpha.4`) still reproduce #352 in CI
    (`deploy.yaml` `terraform apply` with `parallelism=10`).

SemVer implication — pinning a pre-release **violates SemVer range semantics**:

*   `version = "0.12.0-beta.0"` is an **exact pin**, not a range. Terraform
    treats pre-releases as outside `~> 0.11` / `~> 0.12.0`.
*   `~> 0.12.0-beta.0` would allow `alpha.6` if published, but no newer alpha
    is known-good; `~> 0.12.0` would allow a future stable that may change
    semantics.
*   `0.12.0-beta.0` is the **only** version that gives clean `plan`/`apply`
    and is available on the registry.

Impact without the pin:

*   `terraform plan` on `environments/proxmox/{dev,prod}` and
    `environments/libvirt/{dev,prod}` flakes with inconsistent plan on every
    second apply, blocking local `just tf-apply` and CI `deploy.yaml`.
*   `ignore_kubernetes_upgrade_drift` (required for `upgrade-k8s` via
    `talos_cluster.kubernetes_version`) cannot be validated.
*   HA bootstrap (`talos_cluster` with `control_plane_nodes = var.cp_ips`,
    `timeouts = { create = "15m", update = "30m" }`) times out because the
    provider never reaches `talos_cluster_health` (`read = "10m"`).

References — last commits before pin:

*   `git log --all --oneline --grep=352 --grep=talos | head -5`:
    ```
    9f3a1c2 fix: pin talos provider to 0.12.0-beta.0 for #352
    4710f8a Update Proxmox and Talos configurations: add schematic files
    ```
*   `CHANGELOG.md` `1.0.1` — `Talos provider 0.11 → 0.12.0-beta.0 (temporary — fixes #352; revert when v0.12.0 is stable)`.
*   `CHANGELOG.md` `2.0.0` — `Terraform required_version >=1.11 ... talos pinned 0.12.0-beta.0 with kubernetes_version now owned by talos_cluster (ignore_kubernetes_upgrade_drift = true)`.

## Decision

Pin `siderolabs/talos` to the **exact** pre-release `0.12.0-beta.0` in all 7
provider declaration sites, with an explicit `TODO` comment linking back to
#352 so the pin is discoverable and reversible.

Pinned files (7):

1.  `environments/proxmox/dev/provider.tf`
2.  `environments/proxmox/prod/provider.tf`
3.  `environments/libvirt/dev/provider.tf`
4.  `environments/libvirt/prod/provider.tf`
5.  `modules/proxmox/provider.tf`
6.  `modules/libvirt/provider.tf`
7.  `modules/talos-cluster/main.tf`

Pattern — environment roots (`environments/*`):

```hcl
talos = {
  source = "siderolabs/talos"
  # TODO: using alpha to fix "inconsistent final plan" bug (https://github.com/siderolabs/terraform-provider-talos/issues/352).
  # Revert to stable when v0.12.0 is released.
  version = "0.12.0-beta.0"
}
```

Pattern — reusable modules (`modules/proxmox`, `modules/libvirt`):

```hcl
talos = {
  source  = "siderolabs/talos"
  version = "0.12.0-beta.0"
}
```

Pattern — `modules/talos-cluster/main.tf` (extended comment):

```hcl
talos = {
  source = "siderolabs/talos"
  # Pre-release 0.12.0-beta.0: latest pre-release fixing "inconsistent final plan" bug (siderolabs/terraform-provider-talos#352).
  # Successor is stable 0.12.0 (not yet released) — switch to "0.12.0" when available.
  version = "0.12.0-beta.0"
}
```

Why exact pin instead of `~> 0.12.0-beta.0`:

*   `~>` would accept `0.12.0-alpha.6` / `beta` that may re-introduce the bug
    or change `talos_machine` schema. Exact pin gives determinism.
*   Dependabot / Renovate still surfaces a PR when `0.12.0` stable appears,
    but will not auto-merge because the constraint is exact — human review
    required (see Restore Guide).

Verification after pin:

```bash
just provider=proxmox env=dev tf-apply   # plan + apply clean
terraform providers -json | jq '.provider_schemas["registry.terraform.io/siderolabs/talos"]'
# → 0.12.0-beta.0 on all 4 roots + 3 modules
```

## Consequences

### Positive

*   **Deterministic `plan`/`apply`** — eliminates #352 on both Proxmox
    (`bpg/proxmox 0.111.1`) and Libvirt (`dmacvicar/libvirt ~>0.9.8`) for all 4
    environments.
*   **Unblocks `ignore_kubernetes_upgrade_drift`** — `talos_machine` can safely
    ignore drift (`talos_cluster.kubernetes_version` is source of truth via
    `upgrade-k8s`), enabling declarative K8s upgrades.
*   **Unblocks `talos_cluster` HA bootstrap** — `talos_cluster.cluster`
    (`depends_on = [talos_machine.control_plane]`) + `data.talos_cluster_health`
    complete without provider panic.
*   **Single known-good binary** — CI `deploy.yaml` (`terraform init -reconfigure`
    + `terraform apply -parallelism=10` / `tf-apply-upgrade -parallelism=1`)
    is reproducible.
*   **Explicit debt** — `TODO` comments in 3 files make the temporary nature
    greppable (`grep -R "0.12.0-beta.0" --include="*.tf"` → 7 hits).

### Negative / Risks

*   **Pre-release risk** — `alpha.5` is not SemVer-stable; SideroLabs may not
    provide long-term support. Mitigated by pinning — no surprise upgrades.
*   **Dependabot blocked** — exact pin prevents automated bumps; updates require
    manual intervention (see Restore Guide).
*   **Registry cache staleness** — `terraform init -upgrade` will not move past
    `alpha.5` until the constraint is changed.
*   **SemVer violation is intentional** — `version = "0.12.0-beta.0"` bypasses
    `~> 0.12.0` conventions; any tooling that enforces `~>` will flag it.
    Accepted because correctness > convention for #352.
*   **Module consumers inherit the pin** — `modules/proxmox`, `modules/libvirt`,
    `modules/talos-cluster` all pin; downstream cannot override without forking.

## Alternatives Considered

1.  **Stay on `0.11` with `talos_machine_configuration_apply` / `talos_machine_bootstrap`:**
    Avoids #352 but blocks `talos_machine`/`talos_cluster` migration and keeps
    deprecated bootstrap. Rejected.
2.  **Range `~> 0.12.0-beta.0` / `>= 0.12.0-beta.0, < 0.13.0`:**
    Would auto-adopt `alpha.6`/`beta` if published, but no newer alpha is
    verified. Rejected — exact pin gives determinism.
3.  **Vendor the provider binary (`terraform providers mirror`):**
    Guarantees binary but adds `~30 MB` blob. Rejected — registry pin suffices.
4.  **Fork `terraform-provider-talos` locally:**
    Requires maintaining a fork and private registry. Rejected — upstream alpha
    already contains the fix.
5.  **Do nothing (flaky plan):**
    Accept occasional `inconsistent final plan` and retry. Rejected — flakes every
    second apply in CI.

## Restore Guide — Switch to stable 0.12.0

> Run this when SideroLabs releases `0.12.0` stable
> (https://github.com/siderolabs/terraform-provider-talos/releases).

1.  **Verify the stable release fixes #352:**

    ```bash
    curl -s https://api.github.com/repos/siderolabs/terraform-provider-talos/releases/tags/v0.12.0 | jq .body
    ```

2.  **Update all 7 files** (`environments/proxmox/{dev,prod}/provider.tf`,
    `environments/libvirt/{dev,prod}/provider.tf`, `modules/proxmox/provider.tf`,
    `modules/libvirt/provider.tf`, `modules/talos-cluster/main.tf`):

    Change `version = "0.12.0-beta.0"` to:

    ```hcl
    version = "~> 0.12.0"
    ```

    Remove the `TODO` comments in the 3 environment files and the extended
    comment in `modules/talos-cluster/main.tf`.

3.  **Upgrade the lockfile:**

    ```bash
    terraform -chdir=environments/proxmox/dev init -upgrade
    terraform -chdir=environments/proxmox/prod init -upgrade
    terraform -chdir=environments/libvirt/dev init -upgrade
    terraform -chdir=environments/libvirt/prod init -upgrade
    ```

4.  **Validate no drift:**

    ```bash
    terraform -chdir=environments/proxmox/dev plan   # should be clean
    terraform providers | grep talos
    # → siderolabs/talos ~> 0.12.0 (0.12.0)
    ```

5.  **Commit and tag:**

    ```bash
    git add environments/*/provider.tf modules/*/provider.tf modules/talos-cluster/main.tf
    git commit -m "chore: bump talos provider 0.12.0-beta.0 → ~>0.12.0 (fix #352 stable)"
    ```

6.  **Clean up:**

    ```bash
    grep -R "0.12.0-beta.0" --include="*.tf" --include="*.md"
    # → 0 hits expected
    ```

## References

*   [siderolabs/terraform-provider-talos#352](https://github.com/siderolabs/terraform-provider-talos/issues/352) — "inconsistent final plan" bug, fixed only on `0.12` branch, verified on `0.12.0-beta.0`.
*   `CHANGELOG.md` `1.0.1` — `Talos provider 0.11 → 0.12.0-beta.0 (temporary — fixes #352; revert when v0.12.0 is stable)`.
*   `CHANGELOG.md` `2.0.0` — `Terraform required_version >=1.11 ... talos pinned 0.12.0-beta.0 with kubernetes_version now owned by talos_cluster`.
*   [SemVer 2.0.0 — Pre-release](https://semver.org/#spec-item-9) — `0.12.0-beta.0 < 0.12.0`; pre-release has lower precedence, requires exact constraint.
*   `modules/talos-cluster/main.tf:1-10` — standalone `required_providers` with extended TODO comment.
*   `environments/proxmox/{dev,prod}/provider.tf`, `environments/libvirt/{dev,prod}/provider.tf` — 4 environment roots with TODO.
*   `modules/proxmox/provider.tf`, `modules/libvirt/provider.tf` — 2 reusable modules, exact pin.
*   [Terraform Registry — siderolabs/talos](https://registry.terraform.io/providers/siderolabs/talos/latest) — `0.12.0-beta.0` `2026-06-25`.

## TODO

*   [ ] Watch https://github.com/siderolabs/terraform-provider-talos/releases for `0.12.0` stable.
*   [ ] When stable ships, run Restore Guide steps 1–6 and delete this TODO.
*   [ ] Verify `terraform fmt -check -recursive` and `terraform validate` pass on all 4 environments after bump.
*   [ ] Update `README.md` provider version table (`bpg/proxmox 0.111.1`, `siderolabs/talos ~>0.12.0`) if present.
*   [ ] Remove `grep -R "0.12.0-beta.0"` workaround notes from runbooks once stable is adopted.

---

*ADR 002 follows MADR 2.3.0 structure, matching ADR 001 formatting.*
*Provenance: git log --all --oneline --grep=352 and CHANGELOG 1.0.1/2.0.0.*
*Status Accepted on 2026-08-28 — intentional pre-release pin until stable.*
*Review trigger: SideroLabs 0.12.0 stable release.*
*Fallback review: 2026-12-31 if no stable version ships.*
*Contact: infra-terraform-talos maintainers.*

