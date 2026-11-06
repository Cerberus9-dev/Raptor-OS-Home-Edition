# Minimum-spec VM test

Use the repository script to create a disposable QEMU/KVM virtual machine from a Raptor OS ISO and test the install/boot experience with constrained resources.

## Default test profile

| Setting | Default |
|---|---:|
| Guest RAM | 4 GiB (4096 MiB) |
| Virtual CPU topology | 2 cores / 4 threads (4 vCPUs) |
| CPU feature baseline | QEMU/libvirt `Skylake-Client` (Core i3-6100 class) |
| Virtual disk | 64 GiB sparse QCOW2 |
| Firmware | UEFI (OVMF) |
| Display | SPICE + virtio video |
| Network | libvirt default NAT network |

The default CPU target is an Intel Core i3-6100: Skylake, 2 physical cores / 4 threads, 3.7 GHz clock, 3 MB cache, and Intel HD Graphics 530. The VM uses QEMU's `Skylake-Client` CPU feature model and a 2-core / 4-thread virtual topology. QEMU/KVM cannot enforce the i3-6100's exact 3.7 GHz clock, cache, memory controller, or HD 530 graphics; the guest uses a virtual display adapter. Host CPU speed still affects execution, so use this for install, boot, desktop, and 4 GiB memory-pressure testing—not as a precise physical performance benchmark.

## Host prerequisites

The host needs hardware virtualization enabled in firmware and working KVM/libvirt support, plus:

- QEMU/KVM
- libvirt and its default NAT network
- `virt-install`, `virsh`, and `qemu-img`
- UEFI OVMF firmware
- `virt-viewer` (recommended, to open the VM display)

On Fedora/Bazzite-family hosts, the relevant packages are typically `@virtualization`, `virt-install`, `virt-viewer`, and `edk2-ovmf`. Package availability and names can vary by image.

Ensure the libvirt daemon is running, your account can access `qemu:///system`, and the libvirt `default` network is active before running the script.

## Run

From the repository root:

```bash
bash tools/test-minimum-requirements-vm.sh /path/to/raptor-os-home-edition.iso
```

Optional overrides:

```bash
bash tools/test-minimum-requirements-vm.sh ./raptor-os.iso \
  --name raptor-os-4gb-test \
  --ram-mib 4096 \
  --vcpus 4 \
  --cpu-model Skylake-Client \
  --disk-gib 64
```

The script creates `~/VirtualMachines/<name>.qcow2` as a sparse disk and starts the VM from the supplied ISO. It does not modify host disks or install anything on the host. In the guest installer, select only the VM's virtual disk.

After installation, eject/detach the ISO using virt-manager or the VM's device menu, then boot from the virtual disk. Test first login, Wi-Fi/network behavior, audio/display, app launch, update manager, and memory pressure. Record whether the system remains responsive at 4 GiB; note that gaming performance and GPU passthrough are not represented by this default virtual display.

To test an even tighter memory profile, rerun with a separate VM name and `--ram-mib 3072`. The requested 4 GiB / Core i3-6100-class profile remains the default.

## Cleanup

Shut down the guest, then remove its libvirt definition and disk:

```bash
virsh -c qemu:///system shutdown raptor-os-minimum-spec
virsh -c qemu:///system undefine raptor-os-minimum-spec --nvram
rm -f ~/VirtualMachines/raptor-os-minimum-spec.qcow2
```

If the VM is already powered off, the shutdown command may report that no action was needed.
