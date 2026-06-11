#!/usr/bin/env bash
# =============================================================================
# Script Name: provision-k3s.sh
# Description: Provisions k3s cluster VMs on Proxmox from a Debian 13
#              cloud-init template. Creates template (VMID 9000) and
#              clones master (103), worker-0 (104), and worker-1 (105).
# Author: Juan Garcia (arpatek)
# Version: 1.0
# =============================================================================

# ──[ Bash Version Check ]─────────────────────────────────────────────────────
if ((BASH_VERSINFO[0] < 4)); then
  printf "provision-k3s.sh requires bash 4 or higher (detected: %s)\n" "$BASH_VERSION" >&2
  exit 1
fi

set -eo pipefail

# ──[ ANSI Color Codes ]───────────────────────────────────────────────────────
declare -A C=(
  [red]=$'\033[0;31m'
  [green]=$'\033[0;32m'
  [yellow]=$'\033[0;33m'
  [blue]=$'\033[0;34m'
  [purple]=$'\033[0;35m'
  [reset]=$'\033[0m'
)

# ──[ Decoration Functions ]───────────────────────────────────────────────────
BANNER()   { printf "%s[%s^%s]%s" "${C[yellow]}" "${C[purple]}" "${C[yellow]}" "${C[reset]}"; }
PLUS()     { printf "%s[%s+%s]%s" "${C[yellow]}" "${C[green]}"  "${C[yellow]}" "${C[reset]}"; }
COMPLETE() { printf "%s[%s*%s]%s" "${C[yellow]}" "${C[blue]}"   "${C[yellow]}" "${C[reset]}"; }
FAILED()   { printf "%s[%s!%s]%s" "${C[yellow]}" "${C[red]}"    "${C[yellow]}" "${C[reset]}"; }

# ──[ Error Trap ]─────────────────────────────────────────────────────────────
trap 'printf "\n%s Provisioning failed. Aborting.\n" "$(FAILED)"' ERR

# ──[ Configuration ]──────────────────────────────────────────────────────────
TEMPLATE_ID=9000
TEMPLATE_NAME="debian-13-cloud"
CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
CLOUD_IMAGE="/tmp/debian-13-genericcloud-amd64.qcow2"
STORAGE="local-lvm"
SSH_KEY="/root/.ssh/id_rsa.pub"

# VM definitions: "VMID:NAME:IP"
VMS=(
  "103:erebus:10.33.111.103"
  "104:sandevistan:10.33.111.104"
  "105:kerenzikov:10.33.111.105"
)

VM_MEMORY=3072
VM_CORES=2
VM_DISK_SIZE="100G"
VM_GATEWAY="10.33.111.1"
VM_NAMESERVER="10.33.111.100"
VM_SEARCHDOMAIN="home.arpa"
VM_CIUSER="sysadmin"

# ──[ Privileged Session Caching ]─────────────────────────────────────────────
sudo -v || exit 1
while true; do
  sudo -n true
  sleep 60
  kill -0 "$$" || exit
done 2>/dev/null &

# ──[ Functions ]──────────────────────────────────────────────────────────────
create_template() {
  printf "%s Downloading Debian 13 cloud image\n" "$(BANNER)"
  wget -O "$CLOUD_IMAGE" "$CLOUD_IMAGE_URL"
  printf "%s Image downloaded\n\n" "$(COMPLETE)"

  printf "%s Creating template VM (VMID %s)\n" "$(BANNER)" "$TEMPLATE_ID"
  sleep 0.5
  sudo qm create "$TEMPLATE_ID" \
    --name "$TEMPLATE_NAME" \
    --memory 2048 \
    --cores 2 \
    --net0 virtio,bridge=vmbr0 \
    --scsihw virtio-scsi-single \
    --machine q35 \
    --cpu host \
    --ostype l26 \
    --balloon 0

  sudo qm importdisk "$TEMPLATE_ID" "$CLOUD_IMAGE" "$STORAGE"

  sudo qm set "$TEMPLATE_ID" \
    --scsi0 "${STORAGE}:vm-${TEMPLATE_ID}-disk-0,discard=on,iothread=1" \
    --ide2 "${STORAGE}:cloudinit" \
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0 \
    --agent enabled=1

  sudo qm template "$TEMPLATE_ID"
  printf "%s Template ready\n\n" "$(COMPLETE)"
}

clone_and_configure() {
  local vmid="$1"
  local name="$2"
  local ip="$3"

  printf "%s Cloning %s (VMID %s)\n" "$(PLUS)" "$name" "$vmid"
  sudo qm clone "$TEMPLATE_ID" "$vmid" --name "$name" --full --storage "$STORAGE"
  sudo qm resize "$vmid" scsi0 "$VM_DISK_SIZE"

  sudo qm set "$vmid" \
    --memory "$VM_MEMORY" \
    --cores "$VM_CORES" \
    --cpu host \
    --numa 0 \
    --balloon 0 \
    --onboot 1 \
    --net0 virtio,bridge=vmbr0,firewall=1 \
    --ipconfig0 "ip=${ip}/24,gw=${VM_GATEWAY}" \
    --nameserver "$VM_NAMESERVER" \
    --searchdomain "$VM_SEARCHDOMAIN" \
    --ciuser "$VM_CIUSER" \
    --sshkeys "$SSH_KEY"

  printf "%s %s configured\n" "$(COMPLETE)" "$name"
  sleep 0.2
}

# ──[ Main ]───────────────────────────────────────────────────────────────────
printf "%s Starting k3s cluster provisioning\n\n" "$(BANNER)"
sleep 1

create_template
sleep 0.5

printf "%s Provisioning VMs\n" "$(BANNER)"
sleep 0.5
for entry in "${VMS[@]}"; do
  IFS=: read -r vmid name ip <<< "$entry"
  clone_and_configure "$vmid" "$name" "$ip"
done
printf "\n"

printf "%s Starting VMs\n" "$(BANNER)"
sleep 0.5
for entry in "${VMS[@]}"; do
  IFS=: read -r vmid name ip <<< "$entry"
  sudo qm start "$vmid"
  printf "%s Started %s\n" "$(PLUS)" "$name"
  sleep 0.2
done

printf "\n%s Provisioning complete. Cloud-init runs on first boot (~60s).\n" "$(COMPLETE)"
printf "%s SSH: ssh %s@10.33.111.103\n" "$(PLUS)" "$VM_CIUSER"
