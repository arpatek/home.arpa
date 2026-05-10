#!/usr/bin/env bash
# Provision the k3s cluster VMs on Proxmox.
#
# Run as root or with sudo on devstem.
# Creates a Debian 13 cloud-init template (VMID 9000) and clones
# three VMs from it: master (103), worker-0 (104), worker-1 (105).
#
# Prerequisites:
#   - /root/.ssh/id_rsa.pub exists (baked into VMs via cloud-init)
#   - local-lvm storage pool has sufficient space (~300GB)

set -euo pipefail

TEMPLATE_ID=9000
MASTER_ID=103
WORKER0_ID=104
WORKER1_ID=105

CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
CLOUD_IMAGE="/tmp/debian-13-genericcloud-amd64.qcow2"

# ── Phase 1: Download cloud image and create template ─────────────────────────

echo "Downloading Debian 13 cloud image..."
wget -O "$CLOUD_IMAGE" "$CLOUD_IMAGE_URL"

echo "Creating template VM shell (VMID $TEMPLATE_ID)..."
qm create $TEMPLATE_ID \
  --name debian-13-cloud \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single \
  --machine q35 \
  --cpu host \
  --ostype l26 \
  --balloon 0

echo "Importing cloud image disk..."
qm importdisk $TEMPLATE_ID "$CLOUD_IMAGE" local-lvm

echo "Configuring template..."
qm set $TEMPLATE_ID \
  --scsi0 local-lvm:vm-${TEMPLATE_ID}-disk-0,discard=on,iothread=1 \
  --ide2 local-lvm:cloudinit \
  --boot order=scsi0 \
  --serial0 socket \
  --vga serial0 \
  --agent enabled=1

echo "Converting to template..."
qm template $TEMPLATE_ID

# ── Phase 2: Clone VMs ────────────────────────────────────────────────────────

echo "Cloning VMs from template..."
qm clone $TEMPLATE_ID $MASTER_ID  --name prod-k3s-master-0 --full --storage local-lvm
qm clone $TEMPLATE_ID $WORKER0_ID --name prod-k3s-worker-0 --full --storage local-lvm
qm clone $TEMPLATE_ID $WORKER1_ID --name prod-k3s-worker-1 --full --storage local-lvm

# ── Phase 3: Resize disks ─────────────────────────────────────────────────────

echo "Resizing disks to 100GB..."
qm resize $MASTER_ID  scsi0 100G
qm resize $WORKER0_ID scsi0 100G
qm resize $WORKER1_ID scsi0 100G

# ── Phase 4: Configure each VM ───────────────────────────────────────────────

COMMON_OPTS="--memory 4096 --cores 2 --cpu host --numa 0 --balloon 0 --onboot 1
             --net0 virtio,bridge=vmbr0,firewall=1
             --nameserver 10.33.111.100
             --searchdomain home.arpa
             --ciuser sysadmin
             --sshkeys /root/.ssh/id_rsa.pub"

echo "Configuring master (VMID $MASTER_ID)..."
qm set $MASTER_ID $COMMON_OPTS \
  --ipconfig0 ip=10.33.111.103/24,gw=10.33.111.1

echo "Configuring worker-0 (VMID $WORKER0_ID)..."
qm set $WORKER0_ID $COMMON_OPTS \
  --ipconfig0 ip=10.33.111.104/24,gw=10.33.111.1

echo "Configuring worker-1 (VMID $WORKER1_ID)..."
qm set $WORKER1_ID $COMMON_OPTS \
  --ipconfig0 ip=10.33.111.105/24,gw=10.33.111.1

# ── Phase 5: Start VMs ────────────────────────────────────────────────────────

echo "Starting VMs..."
qm start $MASTER_ID
qm start $WORKER0_ID
qm start $WORKER1_ID

echo "Done. Cloud-init runs on first boot (~60s)."
echo "SSH in with: ssh sysadmin@10.33.111.103"
