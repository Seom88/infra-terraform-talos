terraform {
  required_version = ">= 1.11"
  backend "local" {}

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.116.0"
    }
    talos = {
      source = "siderolabs/talos"
      # TODO: alpha fixes inconsistent final plan (issue #352); revert to 0.12.0 when stable.
      version = "0.12.0-beta.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}

provider "proxmox" {
  insecure  = var.insecure
  endpoint  = var.endpoint
  api_token = var.api_token
  ssh {
    agent    = true
    username = var.ssh_username
    node {
      name    = var.node_name
      address = var.ssh_node_address
    }
  }
}

provider "helm" {
  kubernetes = {
    config_path = "${path.module}/../../../secrets/proxmox/${var.env_name}/kubeconfig.yaml"
  }
}
