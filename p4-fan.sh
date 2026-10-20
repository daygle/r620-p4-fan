#!/bin/bash
# GPU-temperature-driven fan control for a Dell R620 (Proxmox host) with a
# passively cooled Tesla P4 passed through to a VM. Settings: /etc/default/p4-fan
#   - Day: normal curve, aims for ~65-70 C.
#   - Night: quieter curve, lets the card run ~70-75 C, ramps hard past 78 C.
#   - Hands the fans back to iDRAC automatic (set iDRAC to Maximum performance
#     + Low Offset as the fallback) when it cannot read the GPU 3 times in a
#     row, when a CPU/exhaust sensor reaches SYSTEM_MAX, or when it stops.
VMID=${VMID:-100}                 # VM the GPU is passed through to
QUIET_FROM=${QUIET_FROM:-20}     # quiet curve from this hour ...
QUIET_UNTIL=${QUIET_UNTIL:-7}    # ... until this hour (host local time)
SYSTEM_MAX=${SYSTEM_MAX:-75}    # CPU/exhaust temp (C) that returns control to iDRAC
INTERVAL=${INTERVAL:-30}        # seconds between checks

auto()   { ipmitool raw 0x30 0x30 0x01 0x01 >/dev/null 2>&1; }
manual() { ipmitool raw 0x30 0x30 0x01 0x00 >/dev/null; }
setpct() { ipmitool raw 0x30 0x30 0x02 0xff "$(printf '0x%02x' "$1")" >/dev/null; }

gpu_temp() {
  qm guest exec "$VMID" --timeout 10 -- \
    nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null \
    | jq -r '."out-data" // empty' 2>/dev/null | tr -dc '0-9'
}

system_temp() {   # hottest IPMI temperature sensor (inlet, exhaust, CPUs)
  ipmitool sdr type temperature 2>/dev/null \
    | grep -oE '[0-9]+ degrees C' | grep -oE '^[0-9]+' | sort -n | tail -1
}

is_quiet() {
  local h=$((10#$(date +%H)))
  if [ "$QUIET_FROM" -gt "$QUIET_UNTIL" ]; then
    [ "$h" -ge "$QUIET_FROM" ] || [ "$h" -lt "$QUIET_UNTIL" ]
  else
    [ "$h" -ge "$QUIET_FROM" ] && [ "$h" -lt "$QUIET_UNTIL" ]
  fi
}

day_curve() {     # GPU C -> fan %
  local t=$1
  if   [ "$t" -ge 80 ]; then echo 60
  elif [ "$t" -ge 76 ]; then echo 50
  elif [ "$t" -ge 72 ]; then echo 40
  elif [ "$t" -ge 68 ]; then echo 30
  elif [ "$t" -ge 62 ]; then echo 25
  else                       echo 20
  fi
}

quiet_curve() {   # GPU C -> fan %, quieter; top steps protect the card
  local t=$1
  if   [ "$t" -ge 82 ]; then echo 40
  elif [ "$t" -ge 78 ]; then echo 35
  elif [ "$t" -ge 74 ]; then echo 30
  elif [ "$t" -ge 68 ]; then echo 25
  elif [ "$t" -ge 62 ]; then echo 20
  else                       echo 15
  fi
}

trap 'auto; exit' EXIT INT TERM
fails=0; last=""; mode=auto
logger -t p4-fan "started (VM $VMID, quiet ${QUIET_FROM}:00-${QUIET_UNTIL}:00)"
while true; do
  t=$(gpu_temp); s=$(system_temp)
  if [ -z "$t" ]; then
    fails=$((fails + 1))
    if [ "$fails" -ge 3 ] && [ "$mode" != auto ]; then
      logger -t p4-fan "cannot read GPU temp from VM $VMID; iDRAC auto"
      auto; mode=auto; last=""
    fi
  elif [ -n "$s" ] && [ "$s" -ge "$SYSTEM_MAX" ]; then
    fails=0
    if [ "$mode" != auto ]; then
      logger -t p4-fan "system sensor ${s}C >= ${SYSTEM_MAX}C; iDRAC auto"
      auto; mode=auto; last=""
    fi
  else
    fails=0
    if is_quiet; then pct=$(quiet_curve "$t"); curve=quiet; else pct=$(day_curve "$t"); curve=day; fi
    if [ "$mode" != manual ]; then manual; mode=manual; last=""; fi
    if [ "$pct" != "$last" ]; then
      setpct "$pct"; last=$pct
      logger -t p4-fan "GPU ${t}C (${curve}) -> fans ${pct}%"
    fi
  fi
  sleep "$INTERVAL"
done
