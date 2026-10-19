#!/bin/bash
# Installs p4-fan on the Proxmox HOST (run as root). The repo must be cloned
# to /opt/r620-p4-fan: the service runs p4-fan.sh from there.
# Prerequisite in the GPU VM:
#   apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent
set -euo pipefail
INSTALL_DIR=/opt/r620-p4-fan
cd "$(dirname "$0")"
say()  { printf '\n== %s\n' "$*"; }
fail() { printf '\n!! %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "run as root on the Proxmox host"
command -v qm >/dev/null || fail "qm not found: this is not the Proxmox host"
[ "$(pwd -P)" = "$INSTALL_DIR" ] || fail "clone this repo to $INSTALL_DIR and run $INSTALL_DIR/install.sh"

if [ ! -f /etc/default/p4-fan ]; then
  install -m 644 p4-fan.default /etc/default/p4-fan
  say "Created /etc/default/p4-fan (edit VMID there if it is not 100)"
fi
# shellcheck disable=SC1091
. /etc/default/p4-fan
VMID=${VMID:-100}

say "Installing ipmitool and jq"
apt-get install -y ipmitool jq >/dev/null

say "Loading IPMI modules"
modprobe ipmi_devintf ipmi_si || true
for m in ipmi_devintf ipmi_si; do grep -qx "$m" /etc/modules || echo "$m" >> /etc/modules; done
ipmitool sdr type temperature >/dev/null 2>&1 || fail "ipmitool cannot read sensors (no local IPMI?)"
ipmitool sdr type temperature | grep -i 'degrees' || true

say "Checking the guest agent option on VM $VMID"
if ! qm config "$VMID" | grep -qE '^agent: (1|.*enabled=1)'; then
  qm set "$VMID" --agent enabled=1 >/dev/null
  fail "agent was just enabled: shut VM $VMID down fully, start it again, then re-run this script"
fi

say "Reading the GPU temperature from VM $VMID"
t=$(qm guest exec "$VMID" --timeout 10 -- nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null \
    | jq -r '."out-data" // empty' | tr -dc '0-9' || true)
[ -n "$t" ] || fail "could not read the GPU temp. In VM $VMID run: apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent"
echo "GPU is ${t}C"

say "Installing the service (runs $INSTALL_DIR/p4-fan.sh)"
chmod 755 p4-fan.sh
install -m 644 p4-fan.service /etc/systemd/system/p4-fan.service
# Older one-shot installs copied the script here; the service no longer uses it.
rm -f /usr/local/bin/p4-fan.sh
systemctl daemon-reload
systemctl enable p4-fan >/dev/null
systemctl restart p4-fan
sleep 5
systemctl --no-pager --lines=0 status p4-fan || true
journalctl -t p4-fan -n 5 --no-pager || true
say "Done. Watch it with: journalctl -t p4-fan -f   Undo with: $INSTALL_DIR/uninstall.sh"
