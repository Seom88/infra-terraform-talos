terraform {
  required_version = ">= 1.11"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.116.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0-beta.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}

