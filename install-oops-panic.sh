#!/usr/bin/env bash
# OPTIONAL hardening - not required for audio. Install it if you value a
# machine that reboots over a machine that hangs.
#
#   bash install-oops-panic.sh
#
# Why this lives in an audio repo: the resume recovery in this repo tears the
# ACP PCI device down after every s2idle resume, and on kernel 7.1.9 that can
# race the driver's own teardown into a corrupted resource tree:
#
#   BUG: kernel NULL pointer dereference, address: 0000000000000050
#   RIP: release_resource+0x34/0x80
#     platform_device_del <- platform_device_unregister <- pci_device_remove
#     <- device_release_driver_internal <- unbind_store
#
# release_resource() holds the global resource_lock for WRITE. The oops kills
# the task with the lock still held, so every later GPU page fault (amdgpu ->
# ttm -> pfnmap_setup_cachemode -> walk_system_ram_range) spins on it forever.
# The desktop freezes solid - no console, no SysRq route back, no clue why.
# Only a power cycle clears it. Seen 2026-09-05 on a HN7306EA, roughly 1 resume
# in 10 before the settle delay in px13-soundwire-recover.sh was raised to 10s.
#
# oops=panic stops the kernel AT the oops instead of letting it limp on with a
# leaked lock; panic=10 then reboots 10s later. panic_on_oops alone is not
# enough: kernel.panic defaults to 0, which hangs at the panic screen and buys
# you nothing.
#
# Two places, on purpose: the cmdline (oops=panic panic=10 - note that
# "panic_on_oops=1" is only a sysctl name, on the cmdline the kernel ignores
# it) and /etc/sysctl.d/99-px13-oops-panic.conf, which systemd-sysctl applies
# at boot even when the UKI has not been rebuilt yet.
#
# This does NOT fix the driver bug. It makes the failure legible and
# self-clearing, and it makes the bug practical to chase - each hit becomes a
# logged oops in the journal plus a reboot, instead of a wedge.
set -euo pipefail

CONF_NAME=oops-panic.conf
PARAMS="oops=panic panic=10"
SYSCTL_NAME=99-px13-oops-panic.conf
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIMINE_DROPIN_DIR=/etc/limine-entry-tool.d

root_run() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

echo "==> 1/3 Applying kernel.panic_on_oops=1 kernel.panic=10 (live + /etc/sysctl.d)"
root_run install -Dm644 "$REPO/configs/$SYSCTL_NAME" "/etc/sysctl.d/$SYSCTL_NAME"
root_run sysctl -q -p "/etc/sysctl.d/$SYSCTL_NAME"
echo "    OK (live now; /etc/sysctl.d/$SYSCTL_NAME re-applies it at every boot)"

echo "==> 2/3 Kernel command line ($PARAMS)"
if [ -d "$LIMINE_DROPIN_DIR" ]; then
  # limine-entry-tool assembles the cmdline from /etc/kernel/cmdline plus these
  # drop-ins. A drop-in survives package updates that rewrite the vendor's own
  # defaults file; editing that file in place does not.
  root_run install -Dm644 "$REPO/configs/$CONF_NAME" "$LIMINE_DROPIN_DIR/$CONF_NAME"
  echo "    installed $LIMINE_DROPIN_DIR/$CONF_NAME"
  if command -v limine-update >/dev/null 2>&1; then
    # Required, not cosmetic: with ENABLE_UKI=yes the cmdline is embedded in
    # the UKI, and with ENABLE_VERIFICATION=yes limine.conf carries a BLAKE2
    # checksum of it. Skip this and you boot the old cmdline, or fail to boot.
    echo "    rebuilding UKI / boot entries (limine-update)"
    root_run limine-update
  else
    echo "    WARNING: limine-update not found - rebuild your boot entries manually"
  fi
else
  cat <<EOF
    No $LIMINE_DROPIN_DIR - you are not on limine-entry-tool.
    Add this to your kernel command line by hand, then regenerate your boot
    config:
        $PARAMS
      GRUB          : GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub,
                      then grub-mkconfig -o /boot/grub/grub.cfg
      systemd-boot  : the options line in /boot/loader/entries/*.conf
      UKI directly  : /etc/kernel/cmdline, then regenerate the UKI
    The sysctl half above is already live either way; without a cmdline entry
    it just will not survive a reboot.
EOF
fi

echo "==> 3/3 Verifying"
printf '    running kernel : panic_on_oops=%s panic=%s\n' \
  "$(cat /proc/sys/kernel/panic_on_oops)" "$(cat /proc/sys/kernel/panic)"
if [ -d "$LIMINE_DROPIN_DIR" ] && command -v objcopy >/dev/null 2>&1; then
  UKI="$(ls -1 /boot/EFI/Linux/*.efi 2>/dev/null | head -1 || true)"
  if [ -n "${UKI:-}" ]; then
    CMDLINE="$(root_run objcopy -O binary --only-section=.cmdline "$UKI" /dev/stdout 2>/dev/null | tr -d '\0')"
    if echo "$CMDLINE" | grep -q "oops=panic"; then
      echo "    embedded UKI cmdline : OK ($UKI)"
    else
      echo "    WARNING: oops=panic not found in $UKI - did limine-update run?"
    fi
    if echo "$CMDLINE" | grep -q "panic_on_oops=1"; then
      echo "    WARNING: the old, ineffective 'panic_on_oops=1' token is still embedded - rerun limine-update"
    fi
  fi
fi
echo
echo "Done. An oops now reboots after 10s instead of freezing."
echo "To revert: rm $LIMINE_DROPIN_DIR/$CONF_NAME /etc/sysctl.d/$SYSCTL_NAME && sudo limine-update"
