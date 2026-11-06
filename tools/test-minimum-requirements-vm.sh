#!/usr/bin/env bash
# Create a low-spec Raptor OS test VM using the locally built/downloaded ISO.
# Default profile: 4 GiB RAM and Intel Core i3-6100-class CPU (Skylake, 2C/4T).
set -Eeuo pipefail

RAM_MIB=4096
VCPUS=4
CPU_MODEL=Skylake-Client
DISK_GIB=64
VM_NAME=raptor-os-minimum-spec
ISO=
CONNECT=qemu:///system

usage() {
  cat <<'USAGE'
Usage:
  bash tools/test-minimum-requirements-vm.sh /path/to/raptor-os.iso [options]

Creates and boots a UEFI QEMU/KVM virtual machine for minimum-spec testing.

Options:
  --name NAME          VM name (default: raptor-os-minimum-spec)
  --ram-mib MIB        Guest memory in MiB (default: 4096)
  --vcpus COUNT        Virtual CPUs/threads (default: 4)
  --cpu-model MODEL    QEMU/libvirt CPU model (default: Skylake-Client)
  --disk-gib GIB       Sparse virtual disk size (default: 64)
  --help               Show this help

The default CPU profile approximates an Intel Core i3-6100 (Skylake, 2 cores,
4 threads). QEMU cannot accurately reproduce its 3.7 GHz clock, cache, memory
controller, or integrated HD 530 graphics. VM performance depends on the host.
USAGE
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

while (($#)); do
  case "$1" in
    --name|--ram-mib|--vcpus|--cpu-model|--disk-gib)
      (($# >= 2)) || die "Missing value for $1"
      key="$1"; value="$2"; shift 2
      case "$key" in
        --name) VM_NAME="$value" ;;
        --ram-mib) RAM_MIB="$value" ;;
        --vcpus) VCPUS="$value" ;;
        --cpu-model) CPU_MODEL="$value" ;;
        --disk-gib) DISK_GIB="$value" ;;
      esac
      ;;
    --help|-h) usage; exit 0 ;;
    -* ) die "Unknown option: $1" ;;
    * )
      [[ -z "$ISO" ]] || die "Only one ISO path may be supplied."
      ISO="$1"; shift
      ;;
  esac
done

[[ -n "$ISO" ]] || { usage >&2; die "Supply the Raptor OS ISO path."; }
[[ -f "$ISO" && -r "$ISO" ]] || die "ISO not found or unreadable: $ISO"
ISO="$(realpath "$ISO")"

[[ "$RAM_MIB" =~ ^[0-9]+$ ]] && ((RAM_MIB >= 2048)) || die "--ram-mib must be an integer of at least 2048."
[[ "$VCPUS" =~ ^[0-9]+$ ]] && ((VCPUS >= 1 && VCPUS <= 32)) || die "--vcpus must be between 1 and 32."
[[ "$DISK_GIB" =~ ^[0-9]+$ ]] && ((DISK_GIB >= 40)) || die "--disk-gib must be an integer of at least 40."
[[ "$VM_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "VM name may contain only letters, numbers, dot, underscore and hyphen."

for command in virt-install virsh qemu-img realpath; do
  command -v "$command" >/dev/null 2>&1 || die "Required command '$command' is missing. Install QEMU/KVM, libvirt and virt-install first."
done

virsh -c "$CONNECT" list --all >/dev/null 2>&1 || die "Cannot access $CONNECT. Start libvirt and grant your account permission to use the system connection."

virsh -c "$CONNECT" net-info default >/dev/null 2>&1 || die "The libvirt 'default' network is missing. Create/enable the default libvirt network first."
if ! virsh -c "$CONNECT" net-info default | grep -q 'Active:.*yes'; then
  die "The libvirt 'default' network is not active. Start it with: sudo virsh net-start default"
fi

if virsh -c "$CONNECT" dominfo "$VM_NAME" >/dev/null 2>&1; then
  die "A VM named '$VM_NAME' already exists. Choose another name with --name."
fi

OVMF_FOUND=0
for firmware in \
  /usr/share/edk2/ovmf/OVMF_CODE.fd \
  /usr/share/OVMF/OVMF_CODE.fd \
  /usr/share/qemu/OVMF_CODE.fd; do
  if [[ -r "$firmware" ]]; then OVMF_FOUND=1; break; fi
done
((OVMF_FOUND == 1)) || die "UEFI OVMF firmware was not found. Install your distribution's edk2-ovmf/OVMF package."

VM_DIR="${HOME}/VirtualMachines"
DISK_PATH="${VM_DIR}/${VM_NAME}.qcow2"
mkdir -p "$VM_DIR"
[[ ! -e "$DISK_PATH" ]] || die "Disk already exists: $DISK_PATH"

info "Creating a sparse ${DISK_GIB} GiB virtual disk at $DISK_PATH"
qemu-img create -f qcow2 "$DISK_PATH" "${DISK_GIB}G" >/dev/null

cleanup_disk() {
  if [[ "${VM_CREATED:-0}" != 1 ]]; then
    rm -f "$DISK_PATH"
  fi
}
trap cleanup_disk EXIT

info "Creating VM: ${RAM_MIB} MiB RAM, ${VCPUS} threads (2 cores x 2 threads), CPU model ${CPU_MODEL}"
virt-install \
  --connect "$CONNECT" \
  --name "$VM_NAME" \
  --memory "$RAM_MIB" \
  --vcpus "$VCPUS" \
  --cpu "$CPU_MODEL" \
  --machine q35 \
  --os-variant generic \
  --boot uefi \
  --disk "path=$DISK_PATH,format=qcow2,bus=virtio" \
  --cdrom "$ISO" \
  --network network=default,model=virtio \
  --graphics spice \
  --video virtio \
  --noautoconsole

VM_CREATED=1
trap - EXIT

cat <<EOF

VM created and started successfully.

VM name:    $VM_NAME
RAM:        ${RAM_MIB} MiB
vCPUs:      $VCPUS
CPU model:  Intel Core i3-6100-class ($CPU_MODEL, 2 cores / 4 threads)
Disk:       $DISK_PATH (${DISK_GIB} GiB, sparse)
Installer:  $ISO

Open its display with:
  virt-viewer --connect $CONNECT $VM_NAME

Useful management commands:
  virsh -c $CONNECT list --all
  virsh -c $CONNECT shutdown $VM_NAME
  virsh -c $CONNECT start $VM_NAME
  virsh -c $CONNECT destroy $VM_NAME   # force-stop only
  virsh -c $CONNECT undefine $VM_NAME --nvram
  rm -f '$DISK_PATH'

Install Raptor OS to the VM's virtual disk, then detach/eject the installer
ISO and boot from disk for the installed-system test. Do not select a physical
host disk in the guest installer.
EOF
