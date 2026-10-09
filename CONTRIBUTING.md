# Contributing to infra-terraform-talos

Thanks for your interest in contributing! This guide will help you get started.

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Terraform](https://www.terraform.io/downloads) | >= 1.11 | Infrastructure provisioning |
| [just](https://github.com/casey/just) | latest | Task runner |
| [Talosctl](https://www.talos.dev/v1.14/introduction/get-started/) | matching `talos_version` | Cluster management |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | latest | Kubernetes CLI |
| [jq](https://stedolan.github.io/jq/) | latest | JSON processing |

### Provider-specific requirements

- **Proxmox**: Proxmox VE 9.x with API token access. See [bpg/proxmox docs](https://registry.terraform.io/providers/bpg/proxmox/latest/docs) for auth setup.
- **Libvirt**: Linux host with libvirt + KVM. The `qemu:///system` connection must be accessible without password.

## Getting started

```bash
# Clone the repo
git clone https://github.com/Seom88/infra-terraform-talos.git
cd infra-terraform-talos

# Pick your provider and environment (provider=<proxmox|libvirt> env=<prod|dev>, defaults proxmox/prod)
just provider=proxmox env=dev tf-apply    # Proxmox dev
just provider=proxmox env=prod tf-apply   # Proxmox prod (same as just tf-apply)
just provider=libvirt env=dev tf-apply    # Libvirt dev
just provider=libvirt env=prod tf-apply   # Libvirt prod
```

## Development workflow

1. **Fork** the repository
2. **Create a branch** from `main` (`git checkout -b feat/my-feature`)
3. **Make your changes** — follow the conventions below
4. **Format** before committing: `just tf-fmt` (runs `terraform fmt -recursive`)
5. **Validate**: `terraform validate` in the relevant directory
6. **Open a PR** against `main`

## Conventions

### Terraform

- Pin provider versions explicitly (exact for critical providers, `~>` for others)
- Use `for_each` over `count` for node resources (clearer addressing)
- Name resources descriptively: `talos_machine.control_plane`, `talos_cluster.cluster`
- Keep provider-specific logic in reusable modules (`modules/proxmox`, `modules/libvirt`), composed from environment roots (`environments/<provider>/<env>/`), not in shared modules

### Secrets

- Never commit `secrets/` — it is `.gitignored` by default
- Never commit `.tfvars` with real credentials
- CI uses GitHub Secrets for Proxmox tokens and Tailscale OAuth credentials (`TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` for subnet-route reachability to `10.10.0.0/24`). The Tailscale Talos node extension is disabled (see ADR 001)

### Commits

- Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `refactor:`, etc.
- Keep commits focused on one logical change
- Reference issues when applicable (`fixes #42`)

## Project structure

```
environments/proxmox/{dev,prod}/  # Proxmox env roots (backend local dev / S3 prod)
environments/libvirt/{dev,prod}/  # Libvirt env roots (backend local dev / S3 prod)
modules/{proxmox,libvirt,talos-cluster,platform}/  # Reusable modules
modules/talos-cluster/            # Provider-agnostic Talos bootstrap & kubeconfig
docs/adr/                         # Architecture Decision Records (MADR)
modules/talos-image/               # Canonical Image Factory wiring (extensions data -> schematic -> URLs)
.github/workflows/                # CI/CD (deploy.yaml, destroy.yaml)
justfile                          # Unified provider=/env= tasks (tf-apply, tf-apply-upgrade, tf-destroy, ...)
```

## Reporting issues

Open a GitHub issue with:

- Provider and version (`bpg/proxmox 0.111.1`, `dmacvicar/libvirt ~>0.9.8`, `siderolabs/talos 0.12.0-beta.0`, etc.)
- Terraform version
- Talos Linux version
- Steps to reproduce
- Expected vs actual behavior

## Questions?

Open a discussion on GitHub or reach out via the project's LinkedIn post.
