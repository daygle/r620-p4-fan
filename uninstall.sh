#!/bin/bash
# Removes p4-fan and hands the fans back to iDRAC. Keeps /etc/default/p4-fan.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
systemctl disable --now p4-fan 2>/dev/null || true
ipmitool raw 0x30 0x30 0x01 0x01 >/dev/null 2>&1 || true
rm -f /etc/systemd/system/p4-fan.service /usr/local/bin/p4-fan.sh
systemctl daemon-reload
echo "p4-fan removed; fans are back under iDRAC control."
