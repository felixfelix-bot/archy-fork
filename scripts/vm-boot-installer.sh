#!/usr/bin/env bash
# Boot an Archipelago installer ISO in a disposable KVM VM and auto-install to
# a scratch disk, then verify FIPS v0.5.3 is the daemon that comes up.
#
# ## Why SATA and not virtio
#
# The installer's disk autodetect (build-auto-installer-iso.sh, "Find internal
# disk") scans ONLY:
#     /dev/nvme*n1        (NVMe)
#     /dev/sd[a-z]        (SATA/SCSI, requires removable=0)
# A virtio-blk disk appears as /dev/vda and is matched by NEITHER pattern, so
# install aborts with "No suitable internal disk found". The scratch disk is
# therefore attached as SATA (ide-hd on q35 gives /dev/sda, removable=0).
# This is a real constraint of the installer, not a VM quirk to paper over.
#
# ## Why the ISO is attached as a SATA CD-ROM too
#
# Same reason: the installer locates its payload by scanning block devices
# including /dev/sr0, and the profile script's mount loop includes /dev/sr0.
# A virtio CD would still show as sr0, but SATA keeps the whole chain on the
# device names the installer actually probes.
#
# Usage: scripts/vm-boot-installer.sh --iso <path> [--ram 3072] [--cpus 2]
#                                      [--disk-gb 24] [--timeout 1800]
#                                      [--keep]
set -uo pipefail

ISO=""; RAM=3072; CPUS=2; DISK_GB=24; TIMEOUT=1800; KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --iso)      ISO="${2:?}"; shift ;;
        --ram)      RAM="${2:?}"; shift ;;
        --cpus)     CPUS="${2:?}"; shift ;;
        --disk-gb)  DISK_GB="${2:?}"; shift ;;
        --timeout)  TIMEOUT="${2:?}"; shift ;;
        --keep)     KEEP=1 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -f "$ISO" ] || { echo "FAIL: ISO not found: ${ISO:-<none>}" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "FAIL: qemu not installed" >&2; exit 1; }
[ -r /dev/kvm ] || { echo "FAIL: /dev/kvm not readable — no hardware acceleration" >&2; exit 1; }

WORK="${VM_WORK:-$HOME/archy-vm}"
mkdir -p "$WORK"
DISK="$WORK/archy-test.qcow2"
LOG="$WORK/console.log"
SERIAL="$WORK/serial.log"

# Fresh disk every run: a stale disk makes the installer skip or clobber state,
# and "it installed" must mean THIS run installed.
rm -f "$DISK" "$LOG" "$SERIAL"
qemu-img create -f qcow2 "$DISK" "${DISK_GB}G" >/dev/null

echo "ISO:    $ISO"
echo "disk:   $DISK (${DISK_GB}G, SATA)"
echo "cpu/ram: $CPUS vCPU / ${RAM}M"
echo "logs:   $LOG, $SERIAL"
echo

# -display none + -serial file: fully headless; the installer's TUI and kernel
# messages go to the serial log, which is what we read.
# -no-reboot: the installer reboots into the installed system, which would loop
# forever under automation. We want the install to COMPLETE, then stop.
timeout "$TIMEOUT" qemu-system-x86_64 \
    -enable-kvm -machine q35 -cpu host -smp "$CPUS" -m "$RAM" \
    -drive "file=$ISO,media=cdrom,if=ide,readonly=on" \
    -drive "file=$DISK,format=qcow2,if=ide,cache=writeback" \
    -boot order=d \
    -display none \
    -serial "file:$SERIAL" \
    -monitor "unix:$WORK/monitor.sock,server,nowait" \
    -no-reboot \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    >"$LOG" 2>&1
RC=$?

echo "qemu exit: $RC"
[ -f "$SERIAL" ] && { echo "--- serial tail ---"; tail -30 "$SERIAL"; }
[ "$KEEP" = "1" ] && echo "kept: $WORK"
exit 0
