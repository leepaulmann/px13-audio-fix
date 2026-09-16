#!/usr/bin/env bash
# Verify the four invariants this fix depends on. Run it after a kernel or
# alsa-ucm-conf update - each of these has already failed silently at least
# once, leaving audio degraded with nothing in the logs.
#
#   bash check-audio.sh          # prints PASS/FAIL per check, exits 1 on any FAIL
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/px13-detect.sh
. "$REPO/lib/px13-detect.sh"

RC=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; printf '        -> %s\n' "$2"; RC=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }

echo "px13-audio-fix - health check on kernel $(uname -r)"
echo

CARD="$(px13_find_card)" || { bad "SoundWire card present" "no card in /proc/asound whose driver mentions soundwire"; exit 1; }
ok "SoundWire card present (card $CARD, $(px13_card_longname "$CARD" || echo '?'))"

# 1. the patched module, not the stock one -----------------------------------
MODPATH="$(modinfo -k "$(uname -r)" snd_soc_tas2783_sdw -F filename 2>/dev/null)"
case "$MODPATH" in
  */updates/*) ok "patched module installed ($MODPATH)" ;;
  "")          bad "patched module installed" "snd_soc_tas2783_sdw not found for this kernel" ;;
  *)           bad "patched module installed" "stock module in use ($MODPATH).
           A kernel update rebuilt nothing. Check: dkms status
           Then: bash install-durable.sh" ;;
esac

if command -v dkms >/dev/null 2>&1; then
  DK="$(dkms status snd-soc-tas2783-sdw-px13 2>/dev/null | grep -c "$(uname -r).*installed")"
  [ "${DK:-0}" -ge 1 ] && ok "DKMS built for this kernel" \
    || bad "DKMS built for this kernel" "dkms status shows no 'installed' line for $(uname -r).
           Usually the driver API moved upstream; see /var/lib/dkms/snd-soc-tas2783-sdw-px13/1.0/build/make.log"
fi

# 1b. the sdw_utils module with the RESUME re-prepare fix ---------------------
SDWU="$(modinfo -k "$(uname -r)" snd_soc_sdw_utils -F filename 2>/dev/null)"
case "$SDWU" in
  */updates/*) ok "sdw_utils RESUME fix installed ($SDWU)" ;;
  *)
    # The stock module may already have it: 7.3, or a distro backport
    # (linux-omarchy 7.2.5) - so look at the code rather than the version.
    FIXRC=0; px13_sdw_utils_has_resume_fix "$SDWU" || FIXRC=$?
    KMM="$(uname -r | cut -d. -f1-2)"
    if [ "$FIXRC" = 0 ]; then
      ok "in-tree sdw_utils carries the RESUME fix (DKMS copy not needed)"
    elif [ "$FIXRC" = 2 ] && [ "$(printf '%s\n7.3\n' "$KMM" | sort -V | head -1)" = 7.3 ]; then
      ok "kernel $KMM carries the sdw_utils RESUME fix in-tree (DKMS copy not needed; binary not checked)"
    else
      warn "sdw_utils RESUME fix NOT active for $(uname -r): a PCM open across suspend comes back silent.
           New kernel series? cd module-sdw-utils && ./fetch-sources.sh && bash ../install-durable.sh"
    fi ;;
esac
for m in snd_soc_tas2783_sdw snd_soc_sdw_utils; do
  MEM="$(cat /sys/module/$m/srcversion 2>/dev/null)"
  DISK="$(modinfo -k "$(uname -r)" $m -F srcversion 2>/dev/null)"
  if [ -n "$MEM" ] && [ -n "$DISK" ] && [ "$MEM" != "$DISK" ]; then
    warn "$m: newer build on disk than in memory - reboot or: sudo PX13_RECOVER_POLICY=always bash test-sdw-module-reload.sh"
  fi
done

# 2. the per-amp channel control ---------------------------------------------
AMPS="$(px13_amp_count "$CARD")"
CH="$(amixer -D "hw:$CARD" controls 2>/dev/null | grep -c 'Channel Playback')"
if [ "${CH:-0}" -ge 2 ]; then
  V1="$(amixer -D "hw:$CARD" cget name='tas2783-1 Channel Playback' 2>/dev/null | sed -n 's/^ *: values=//p')"
  V2="$(amixer -D "hw:$CARD" cget name='tas2783-2 Channel Playback' 2>/dev/null | sed -n 's/^ *: values=//p')"
  if [ "${V1:-0}" != "${V2:-0}" ] && [ "${V1:-0}" != 0 ] && [ "${V2:-0}" != 0 ]; then
    ok "stereo channel assignment (amp1=$V1 amp2=$V2, 1=Left 2=Right)"
  else
    bad "stereo channel assignment" "both amps on the same channel (amp1=${V1:-?} amp2=${V2:-?}) -> mono.
           Reapply the profile: systemctl --user restart wireplumber pipewire"
  fi
elif [ "${AMPS:-0}" -lt 2 ]; then
  warn "only ${AMPS:-0} amp(s) with controls - single-amp variant, mono is expected"
else
  # "installed on disk" and "running in memory" are different things: modprobe -r
  # fails while the stack is in use, so a fresh install can sit there unloaded.
  MEM="$(cat /sys/module/snd_soc_tas2783_sdw/srcversion 2>/dev/null)"
  DISK="$(modinfo -k "$(uname -r)" snd_soc_tas2783_sdw -F srcversion 2>/dev/null)"
  if [ -n "$MEM" ] && [ -n "$DISK" ] && [ "$MEM" != "$DISK" ]; then
    bad "stereo channel assignment" "the patched module is installed but the OLD one is still in memory
           (srcversion $MEM in memory vs $DISK on disk).
           Reboot, or reload the whole stack: sudo bash test-sdw-module-reload.sh"
  else
    bad "stereo channel assignment" "no 'Channel Playback' control: the stock driver is loaded, not the patched one."
  fi
fi

# 3. UCM exposes a Speaker device --------------------------------------------
if alsaucm -c "$CARD" list _devices/HiFi 2>/dev/null | grep -qw Speaker; then
  ok "UCM exposes a Speaker device"
else
  bad "UCM exposes a Speaker device" "the long-name override is missing or under another SKU's name.
           Run: bash install-durable.sh"
fi

# 4. the sink is actually audible --------------------------------------------
if SINK="$(px13_pw_speaker_sink)"; then
  MUTE="$(pactl get-sink-mute "$SINK" 2>/dev/null | awk '{print $2}')"
  VOL="$(pactl get-sink-volume "$SINK" 2>/dev/null | sed -n 's/.*\/ *\([0-9]\+\)%.*/\1/p' | head -1)"
  if [ "${MUTE:-no}" = yes ]; then
    bad "speaker sink audible" "sink is muted: pactl set-sink-mute $SINK 0"
  elif [ -n "${VOL:-}" ] && [ "$VOL" -eq 0 ] 2>/dev/null; then
    bad "speaker sink audible" "sink volume is 0% - silent while everything else looks right.
           Fix: pactl set-sink-volume $SINK 60%"
  else
    ok "speaker sink audible (volume ${VOL:-?}%, not muted)"
  fi
else
  bad "speaker sink audible" "PipeWire shows no SoundWire speaker sink"
fi

echo
[ "$RC" = 0 ] && echo "All good. Play something: speaker-test -D pulse -c2 -l1 -t wav" \
              || echo "Something is off - see the arrows above."

# 6. resume health: driver state, recovery policy, oops hardening ------------
FWS="$(px13_tas2783_fw_states)"; FWRC=$?
case "$FWRC" in
  0) ok "amp firmware state ($FWS)" ;;
  2) warn "no fw_state attribute - codec module older than 1.1 (bash install-durable.sh)" ;;
  *) bad "amp firmware state" "$FWS - an amp is attached but not initialised.
           Fallback: sudo PX13_RECOVER_POLICY=always /usr/local/lib/px13-soundwire-recover.sh" ;;
esac
POLICY="$(px13_cache_get PX13_RECOVER_POLICY 2>/dev/null || true)"
case "${POLICY:-auto}" in
  auto)   ok "resume recovery policy: auto (reload only when the driver failed)" ;;
  always) warn "resume recovery policy: always (full reload + PipeWire restart on every resume; Brave loses its mic)" ;;
  never)  warn "resume recovery policy: never (no fallback if the driver fails to recover)" ;;
  *)      warn "resume recovery policy '$POLICY' unknown - treated as auto" ;;
esac
if [ "$(cat /proc/sys/kernel/panic_on_oops 2>/dev/null)" = 1 ]; then
  ok "kernel.panic_on_oops=1 (an oops reboots instead of freezing)"
else
  warn "kernel.panic_on_oops=0 - an oops in the audio teardown freezes the machine; bash install-oops-panic.sh"
fi

exit "$RC"
