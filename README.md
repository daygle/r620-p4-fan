# r620-p4-fan

GPU-temperature fan control for a **Dell PowerEdge R620** running **Proxmox**
with a passively cooled **NVIDIA Tesla P4** passed through to a VM.

iDRAC cannot see a third-party PCIe card's temperature, so it keeps the fans
slow while the P4 cooks (86-88 °C at 26 W in a 28 °C garage). Fan Speed Offset
fixes the heat but is loud all the time. This service reads the P4's
temperature from inside the VM every 30 s and sets the fans to match: quiet
when the card is cool, faster only when it needs it, with a quieter curve at
night.

## How it works

- Runs on the **Proxmox host**: only the host can drive the fans (`ipmitool`).
- Reads the GPU through the **QEMU guest agent**:
  `qm guest exec <VMID> -- nvidia-smi ...` (the passed-through card is only
  visible inside the VM).
- Logs each fan change to the journal (`journalctl -t p4-fan`).

| GPU °C | Day fans | Night fans |
|---|---|---|
| < 62 | 20% | 15% |
| 62-67 | 25% | 20% |
| 68-71 | 30% | 25% |
| 72-73 | 40% | 25% |
| 74-75 | 40% | 30% |
| 76-77 | 50% | 30% |
| 78-79 | 50% | 35% |
| 80-81 | 60% | 35% |
| ≥ 82 | 60% | 40% |

Day aims for about 65-70 °C, night for about 70-75 °C. The P4 slows itself
down at 91 °C and shuts off at 94 °C.

### Safety

The fans go back to **iDRAC automatic control** when:

- the GPU temperature cannot be read 3 times in a row;
- any IPMI temperature sensor (CPUs, exhaust) reaches `SYSTEM_MAX` (75 °C);
- the service stops or crashes (`trap` + `ExecStopPost`).

Set iDRAC's fallback to something that is safe for the P4 on its own: on this
server **Thermal Base Algorithm: Maximum performance** with **Fan Speed Offset:
Low** held the card at about 70 °C (F2 → iDRAC Settings → Thermal). If the
server suddenly gets loud, the script is not in control: check
`systemctl status p4-fan`.

## Install

1. In the GPU VM:

   ```bash
   apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent
   ```

2. On the Proxmox host, as root:

   ```bash
   apt install -y git
   git clone https://github.com/daygle/r620-p4-fan.git /opt/r620-p4-fan
   /opt/r620-p4-fan/install.sh
   ```

   Proxmox does not ship `git`, hence the first line.

   The repo must live at **`/opt/r620-p4-fan`**: the service runs
   `p4-fan.sh` from there, and `install.sh` refuses to run anywhere else.

   The installer creates `/etc/default/p4-fan`, installs `ipmitool` and `jq`,
   loads the IPMI modules, enables the guest agent option on the VM, checks it
   can read both the server's sensors and the GPU, then installs and starts
   the service. If it has to enable the guest agent option, shut the VM down
   fully, start it again, and run `install.sh` again.

3. Watch it:

   ```bash
   journalctl -t p4-fan -f
   # GPU 71C (day) -> fans 30%
   ```

## Configure

Edit `/etc/default/p4-fan`, then `systemctl restart p4-fan`:

| Setting | Default | |
|---|---|---|
| `VMID` | `100` | VM the GPU is passed through to |
| `QUIET_FROM` / `QUIET_UNTIL` | `20` / `7` | Night curve hours, host local time (`timedatectl`) |
| `SYSTEM_MAX` | `75` | Sensor temperature that hands control back to iDRAC |
| `INTERVAL` | `30` | Seconds between checks |

The curves are `day_curve` and `quiet_curve` in `p4-fan.sh`. Change the
percentages there and run `systemctl restart p4-fan`. Some R620s report fan warnings
below about 12-15%.

## Update / uninstall

```bash
cd /opt/r620-p4-fan
git pull && ./install.sh     # update (keeps /etc/default/p4-fan)
./uninstall.sh               # remove the service; fans back to iDRAC
```

`uninstall.sh` leaves `/opt/r620-p4-fan` and `/etc/default/p4-fan` in place;
delete them yourself if you no longer want them.

## Manual fan commands

```bash
ipmitool raw 0x30 0x30 0x01 0x00         # manual control
ipmitool raw 0x30 0x30 0x02 0xff 0x28    # all fans 40% (hex percent)
ipmitool raw 0x30 0x30 0x01 0x01         # back to iDRAC automatic
```
