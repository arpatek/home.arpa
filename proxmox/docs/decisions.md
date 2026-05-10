# Decisions

The design choices behind this Proxmox deployment.

## Proxmox VE over XCP-ng

**Decision.** The lab hypervisor runs Proxmox VE 9.

**Background.**
The ASUS PN51 previously ran XCP-ng — a Xen-based hypervisor and the platform used for an earlier homelab where Terraform, Ansible, and Puppet were practiced against real VMs.
The switch to Proxmox was deliberate: XCP-ng was a known quantity and Proxmox was not.

**Alternatives considered.**

_XCP-ng._ Open-source Xen-based hypervisor, fork of XenServer/Citrix Hypervisor.
Production-grade, used in enterprise environments.
Good Terraform provider support.
The prior homelab ran on it successfully.

_VMware ESXi._ Industry-standard enterprise hypervisor.
Requires a license for full features.
Broadcom's acquisition of VMware has made the free tier significantly more restrictive since 2024.

_Bare metal._ Run services directly on the host without a hypervisor.
Simpler, but loses isolation, snapshotting, and the ability to run multiple OS environments simultaneously.

**Why Proxmox.**

Proxmox is KVM-based rather than Xen-based.
KVM is the Linux kernel's native virtualization module and is what most cloud providers (AWS Nitro, GCP, many others) use under the hood.
Learning Proxmox/KVM maps more directly to the cloud virtualization layer than Xen does.

The community and documentation are strong.
Proxmox has an active forum, extensive documentation, and a large homelab community producing tutorials and tooling.

The existing XCP-ng hardware was being repurposed anyway.
Switching hypervisors had no hardware cost — only a reinstall.

## ASUS PN51 hardware

**Decision.** The hypervisor runs on an ASUS PN51 Mini PC with a Ryzen 7, 32GB RAM, and two SSDs.

**Why this hardware.**

The PN51 was already owned and previously used as the XCP-ng hypervisor.
Repurposing existing hardware rather than buying dedicated server hardware is a deliberate homelab philosophy — learn on real infrastructure without the cost and noise of rack-mounted servers.

The Ryzen 7 provides AMD-V virtualization extensions, 8 cores / 16 threads, and enough headroom to run six simultaneous VMs without contention.
32GB RAM allows each VM to have its dedicated allocation with headroom remaining.

The Mini PC form factor keeps the lab physically compact and power-efficient.

## LVM thin over directory storage for VM disks

**Decision.** VM disks use `local-lvm` (LVM thin pool) rather than the `local` directory storage.

**Alternatives considered.**

_Directory storage (qcow2 files)._ Store VM disks as qcow2 image files in a directory.
The `local` pool works this way.
Simpler to manage and inspect — disk files are visible in the filesystem.

**Why LVM thin.**

Thin provisioning is more space-efficient.
A VM declared with 100GB only consumes the space it actually writes.
Six VMs with 100GB each don't require 600GB upfront.

Performance is better.
LVM volumes are raw block devices — no filesystem overhead, no qcow2 format translation.
I/O goes directly to the block layer.

Snapshots are more efficient.
LVM thin snapshots use copy-on-write at the block level, which is faster and more space-efficient than qcow2 snapshots.

## Single-node deployment

**Decision.** Proxmox runs as a standalone single node, not as part of a Proxmox cluster.

**Why.**

Proxmox clustering requires a minimum of three nodes for quorum — the cluster consensus mechanism that prevents split-brain scenarios.
A two-node cluster without a quorum device is not reliable.
A three-node cluster requires two more machines.

For a single-machine homelab, single-node Proxmox is the appropriate deployment.
All cluster features that matter for this use case (VM management, storage, snapshots) work fully on a single node.
High availability and live migration require a cluster, but those aren't requirements here.
