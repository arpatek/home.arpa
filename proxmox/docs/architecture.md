# Architecture

What Proxmox VE actually is and how it runs virtual machines.

For why specific choices were made, see [decisions.md](decisions.md).
For things that broke during setup, see [gotchas.md](gotchas.md).

## What Proxmox VE is

Proxmox VE is a Debian-based Linux distribution with a hypervisor management stack built on top.
It is not a hypervisor itself — it is a management layer over two underlying Linux virtualization technologies:

**KVM (Kernel-based Virtual Machine)** — the hypervisor.
A Linux kernel module that allows the kernel to act as a type-1 hypervisor, giving VMs direct access to hardware CPU virtualization extensions (AMD-V on this host).
Each VM runs as a KVM process on the host.

**QEMU** — the hardware emulator.
Provides the virtual hardware (CPU, disk controllers, network cards, firmware) that VMs see.
Proxmox uses QEMU with KVM acceleration — QEMU handles device emulation, KVM handles CPU and memory virtualization at near-native speed.

**The Proxmox management stack** runs on top:

- `pvedaemon` — the cluster and VM management daemon
- `pveproxy` — serves the web UI over HTTPS on port 8006
- `pve-manager` — the CLI tools (`qm`, `pvesm`, `pvesh`, etc.)
- `corosync` / `pve-cluster` — cluster coordination (not actively used on a single node)

## Storage

Proxmox supports multiple storage backends simultaneously.
This host uses two:

**`local` (directory)** — a standard filesystem directory (`/var/lib/vz/`) on the WD Black 2TB M.2.
Used for ISO images, container templates, and Proxmox's own state.
Simple, no special features.

**`local-lvm` (LVM thin pool)** — a thin-provisioned LVM pool on the same WD Black 2TB M.2.
All VM disks live here.
Thin provisioning means a VM with a 100GB disk allocation only consumes actual written data — a freshly created VM uses ~3GB of physical space regardless of its declared disk size.
Supports snapshots and `discard` (TRIM) for reclaiming freed space.

**`data` (directory)** — a standard filesystem directory on the WD Blue 500GB SSD.
Secondary storage, available for large files, backups, or additional ISOs.

## Networking

A single Linux bridge (`vmbr0`) connects all VMs to the physical network.

```
Physical NIC (nic0)
        │
    vmbr0 (10.33.111.44/24)
        │
   ┌────┴────┐
   VM   VM   VM  ...
```

When a VM's virtual NIC is attached to `vmbr0`, it behaves like a device plugged into the same switch as the physical host.
The VM gets its own IP on `10.33.111.0/24` — either from Pi-hole DHCP or configured statically via cloud-init.
The hypervisor host itself (`devstem`) also lives on `vmbr0` at `10.33.111.44`.

## VM configuration

Each VM is defined by a configuration file in `/etc/pve/qemu-server/<vmid>.conf`.
Proxmox writes and manages these files — editing them directly is possible but `qm set` is the standard interface.

The configuration covers:
- Machine type (`q35` for all lab VMs — the modern QEMU machine type with PCIe support)
- vCPU count and type (`host` — passes through the physical CPU flags, maximizing performance and compatibility)
- RAM allocation
- Disk references (LVM volumes on `local-lvm`)
- Network interfaces
- Boot order
- Cloud-init settings (for template-based VMs)
- QEMU Guest Agent state

## Web UI

The Proxmox web interface runs at `https://devstem.home.arpa:8006`.
It provides VM lifecycle management, console access, resource monitoring, storage management, and backup scheduling.
All operations available in the UI are also available via the `qm`, `pvesm`, and `pvesh` CLI tools.
