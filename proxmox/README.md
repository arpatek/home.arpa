# Proxmox

## Host

|              |                                        |
| ------------ | -------------------------------------- |
| Hardware     | ASUS PN51 Mini PC                      |
| CPU          | AMD Ryzen 7 (8 cores / 16 threads)     |
| RAM          | 32GB                                   |
| Storage      | WD Black 2TB M.2 SSD, WD Blue 500GB SSD |
| OS           | Proxmox VE 9.1.9                       |
| Kernel       | 7.0.0-3-pve                            |
| IP           | 10.33.111.44                           |
| Hostname     | blackwall.home.arpa                      |

## Overview

Proxmox VE hypervisor running all lab VMs.
Single-node deployment — no cluster, no HA.
All VMs run on a single LVM thin pool (`local-lvm`) on the primary drive.

## Storage

| Pool        | Type     | Total    | Drive              | Notes                      |
| ----------- | -------- | -------- | ------------------ | -------------------------- |
| `local`     | dir      | 98GB     | WD Black 2TB M.2   | Proxmox OS, ISO storage    |
| `local-lvm` | lvmthin  | 1.79TB   | WD Black 2TB M.2   | All VM disks               |
| `data`      | dir      | 479GB    | WD Blue 500GB SSD  | Secondary storage          |

All VM disks use `local-lvm`.
LVM thin provisioning means storage is allocated on write, not upfront.
Snapshots and `discard=on` (TRIM) are supported.

## Network

Single bridge `vmbr0` on `10.33.111.0/24`.
All VMs attach to `vmbr0` and receive IPs from Pi-hole DHCP or via cloud-init static assignment.

## VM inventory

| VMID | Name                  | Status   | vCPUs | RAM    | Disk   | IP              |
| ---- | --------------------- | -------- | ----- | ------ | ------ | --------------- |
| 100  | mikoshi            | running  | 2     | 3GB    | 80GB   | 10.33.111.100   |
| 101  | soulkiller            | running  | 4     | 4GB    | 80GB   | 10.33.111.101   |
| 102  | netwatch            | running  | 2     | 4GB    | 100GB  | 10.33.111.102   |
| 103  | erebus     | running  | 2     | 4GB    | 100GB  | 10.33.111.103   |
| 104  | sandevistan     | running  | 2     | 4GB    | 100GB  | 10.33.111.104   |
| 105  | kerenzikov     | running  | 2     | 4GB    | 100GB  | 10.33.111.105   |
| 200  | gonk-01             | stopped  | 2     | 4GB    | 64GB   | 10.33.111.200   |
| 201  | gonk-02             | stopped  | 2     | 4GB    | 64GB   | 10.33.111.201   |
| 9000 | debian-13-cloud       | template | —     | —      | 3GB    | —               |

## Repository layout

```
proxmox/
├── README.md                   # this file — host info and VM inventory
├── provision-k3s.sh            # VM provisioning script for the k3s cluster
└── docs/
    ├── architecture.md         # KVM/QEMU stack, storage backends, bridge networking
    ├── decisions.md            # Proxmox vs XCP-ng, hardware choice, storage layout
    ├── gotchas.md              # enterprise repo issue on fresh install
    └── upgrading.md            # package and major version upgrade procedures
```

## Useful commands

```bash
# List all VMs
sudo qm list

# Check resource usage on the host
sudo pvesh get /nodes/blackwall/status

# Start / stop a VM
sudo qm start <vmid>
sudo qm stop <vmid>

# Check storage pools
sudo pvesm status

# Get VM config
sudo qm config <vmid>
```
