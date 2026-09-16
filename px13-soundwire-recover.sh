#!/bin/bash
# PX13 - SoundWire audio recovery after s2idle resume (FALLBACK).
# Runs as a transient unit (systemd-run) fired by the sleep hook
# /usr/lib/systemd/system-sleep/50-px13-soundwire - NEVER inline in the resume
# path, or the user session stays frozen (black screen) until it finishes.
#
# Since module 1.1 the amps recover on their own: the codec driver carries the
# 7.3 resume fixes (stale regcache dropped on re-attach, PDE powered before
# port prepare, firmware replayed from memory, bounded retry) and sdw_utils
# re-prepares the SoundWire stream on SNDRV_PCM_TRIGGER_RESUME. The card never
# actually disappears across s2idle - the slaves come back Attached by
# themselves - so on a healthy resume this script must NOT touch anything:
# every PipeWire restart disconnects Chromium's audio service (no mic in Brave
# until it is restarted) and the PCI teardown below has oopsed the kernel.
#
# PX13_RECOVER_POLICY (env, else /etc/px13-audio-fix.conf, default auto):
#   auto   - health check (slaves Attached, fw_state ok, no resume errors in the
#            kernel log); reload only when it fails
#   always - unconditional reload (the pre-1.1 behaviour)
#   never  - log and exit (driver testing)
#
# The fallback itself: FULL RELOAD of the SoundWire/ACP module stack (validated
# 2026-07-30; a shallow PCI unbind/bind did not re-enumerate on 7.1.5).
#
#   - STOP the session's PipeWire FIRST, then unbind PCI -> rmmod stack
#     (children first) -> modprobe -> bind. Unloading the codec while userspace
#     still holds the ALSA card blocks forever in snd_card_disconnect_sync():
#     an unkillable D state that can only be cleared by a reboot (seen on
#     7.2.2, 2026-09-01). 7.1 tolerated restarting PipeWire afterwards; 7.2
#     does not;
#   - wait for Attached (up to 20 s);
#   - restart the session's PipeWire (it was stopped above; a vanished card
#     wedges the WirePlumber graph and kills even Bluetooth audio - 2026-07-29);
#   - on success: reapply the HiFi profile and unmute the speaker (only becomes
#     the default sink if the current default is auto_null, so it never steals
#     from a Bluetooth headset);
#   - restart Chromium/Electron audio services so browsers see the mic again.
#
# Nothing here is hardcoded to one PX13 SKU: the PCI address, the PipeWire card
# and the speaker sink are all probed (see lib/px13-detect.sh).
#
# Install: bash install-resume-recovery.sh
# Manual run: sudo /usr/local/lib/px13-soundwire-recover.sh
set -u

DETECT="${PX13_DETECT_LIB:-/usr/local/lib/px13-audio-detect.sh}"
LOG="/var/log/px13-soundwire-resume.log"
log() { echo "$(date '+%F %T' 2>/dev/null || echo now) $*" >> "$LOG" 2>/dev/null; }

if [ ! -r "$DETECT" ]; then
  log "ERRO: $DETECT ausente - rode install-resume-recovery.sh"
  exit 1
fi
# shellcheck source=lib/px13-detect.sh
. "$DETECT"

# Give the resume time to finish and the session to thaw before touching
# anything. This is NOT just cosmetic politeness: at sleep 2 the unbind below
# lands ~2 s after "PM: suspend exit", while the ACP is still settling, and it
# raced the driver's own teardown into a corrupted resource tree:
#
#   BUG: kernel NULL pointer dereference, address: 0000000000000050
#   RIP: release_resource+0x34/0x80
#     platform_device_del <- platform_device_unregister <- pci_device_remove
#     <- device_release_driver_internal <- unbind_store   (7.1.9, 2026-09-05)
#
# release_resource() holds the global resource_lock for write, so the oops left
# it locked forever: every later GPU page fault (amdgpu_gem_fault -> ttm ->
# pfnmap_setup_cachemode -> walk_system_ram_range) spun on it and the whole
# desktop froze hard (soft lockups in quickshell and brave; only a power cycle
# cleared it). Roughly 1 resume in 10.
#
# On healthy resumes SoundWire re-enumeration does not even report in until
# ~t+7 s, so 10 s puts the teardown well clear of the resume path. Dropping the
# sysfs unbind would NOT help - modprobe -r snd_pci_ps runs the same
# pci_device_remove path. The lever is when, not how.
sleep "${PX13_RESUME_SETTLE:-10}"

PCI="$(px13_acp_pci)" || PCI=""
if [ -z "$PCI" ]; then
  log "ERRO: nao achei o dispositivo PCI do ACP (nem no cache $PX13_CACHE)"
  exit 1
fi
DRV="$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null)"
[ -n "$DRV" ] || DRV="/sys/bus/pci/drivers/snd_pci_ps"
log "recover: iniciando em background (ACP $PCI, driver $(basename "$DRV"))"

is_bound() { [ -e "/sys/bus/pci/devices/$PCI/driver" ]; }

# --- session user (needed BEFORE the reload, see below) --------------------
UNAME="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 ~ /seat/ { print $3; exit }')"
[ -z "${UNAME:-}" ] && UNAME="$(id -nu 1000 2>/dev/null || echo root)"
UID_="$(id -u "$UNAME" 2>/dev/null || echo 1000)"; RT="/run/user/$UID_"
ru() { runuser -u "$UNAME" -- env XDG_RUNTIME_DIR="$RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" "$@" 2>>"$LOG"; }

# Release the ALSA card BEFORE unloading anything. Removing the codec driver
# while userspace still holds the card blocks forever in
# snd_card_disconnect_sync() - an unkillable D state that takes the reboot with
# it (kernel 7.2.2, 2026-09-01). On 7.1 the same script got away with
# restarting PipeWire afterwards; do not rely on that.
release_card() {
  if [ -S "$RT/bus" ]; then
    # The .socket units have to go too. Stopping only the services leaves
    # socket activation armed: systemd respawns PipeWire on the next access, it
    # re-opens /dev/snd, and the check below then aborts the reload EVERY time.
    # systemd says so itself in the journal:
    #   Stopping 'pipewire.service', but its triggering units are still active:
    #   pipewire.socket
    # Waiting longer does not help - the socket has to be down.
    ru systemctl --user stop wireplumber pipewire pipewire-pulse \
                              pipewire.socket pipewire-pulse.socket
    log "recover: pipewire+sockets parados antes do reload (libera o card)"
  fi
  # fuser prints the PIDs on stdout and the file name on stderr.
  # Poll rather than sleep a fixed amount: with the sockets down the release is
  # usually immediate, but it is not instantaneous.
  local i pids names
  for i in $(seq 1 "${PX13_RELEASE_WAIT:-15}"); do
    pids="$(fuser /dev/snd/* 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
    if [ -z "$pids" ]; then
      log "recover: /dev/snd liberado apos ${i}s"
      return 0
    fi
    sleep 1
  done
  names="$(ps -o comm= -p $pids 2>/dev/null | sort -u | tr '\n' ' ')"
  log "AVISO: /dev/snd ainda aberto por [$pids] $names - o rmmod travaria"
  return 1
}

# --- policy / health check ---------------------------------------------------
# Before module 1.1 this reloaded unconditionally ("the amp firmware does not
# survive s2idle"). It does now: the driver re-downloads it on re-attach and
# reports the outcome in sysfs (fw_state), so the reload is only for the cases
# the driver could not handle (e.g. rt721 "failed to resume: -110" after very
# long sleeps).
POLICY="${PX13_RECOVER_POLICY:-$(px13_cache_get PX13_RECOVER_POLICY 2>/dev/null || true)}"
case "${POLICY:-auto}" in auto|always|never) ;; *) log "recover: unknown policy '$POLICY' - using auto"; POLICY=auto ;; esac
POLICY="${POLICY:-auto}"
case "$POLICY" in
  never)
    log "recover: policy=never - leaving the stack alone (slaves:$(px13_sdw_status_str))"
    exit 0 ;;
  auto)
    FW="$(px13_tas2783_fw_states)"; FWRC=$?
    ERRS="$(px13_resume_errors)"
    if is_bound && px13_sdw_all_attached && [ "$FWRC" != 1 ] && [ -z "$ERRS" ]; then
      log "recover: healthy, nothing to do (fw:${FW:-no attribute} slaves:$(px13_sdw_status_str))"
      exit 0
    fi
    log "recover: NOT healthy -> full reload (bound=$(is_bound && echo y || echo n) fw:${FW:-?} slaves:$(px13_sdw_status_str) errors=$(printf '%s' "$ERRS" | grep -c .))"
    [ -n "$ERRS" ] && printf '%s\n' "$ERRS" | sed 's/^/    /' >> "$LOG" ;;
  always)
    log "recover: policy=always - unconditional reload (slaves:$(px13_sdw_status_str))" ;;
esac

# --- full module reload (order derived from lsmod at run time, see below) -----
if ! release_card; then
  log "recover: ABORTANDO o reload - o card segue em uso e o rmmod travaria o kernel"
  [ -S "$RT/bus" ] && ru systemctl --user start pipewire.socket pipewire-pulse.socket \
                                                  wireplumber pipewire pipewire-pulse
  exit 1
fi
[ -e "/sys/bus/pci/devices/$PCI/driver" ] && { echo "$PCI" > "$DRV/unbind" 2>>"$LOG"; sleep 1; }

# Unload order is derived from lsmod, not from a list (ported from upstream
# ftoleedo/px13-audio-fix 9bec25a). A fixed list rots with every kernel: the
# one mapped on 7.1.5 knew snd_sof_amd_acp70/acp63/..., but 7.3 and
# linux-omarchy 7.2.5 also load snd_sof_amd_acp7x - not on the list, so it
# stayed loaded, kept snd_sof_amd_acp busy, which kept soundwire_amd busy,
# which kept soundwire_generic_allocation busy: "rmmod FALHOU" on every
# fallback and no SoundWire master reload at all.
#
# Instead: take every loaded module of the ACP/SoundWire stack (pattern below,
# codec sets included so rt711/rt722/cs35l56/... machines work too) and unload,
# in passes, whichever ones have a zero refcount, until the set is empty or a
# pass removes nothing. Children fall first by construction.
is_stack_module() {
  case "$1" in
    snd_soc_rt[0-9]*|snd_soc_tas[0-9]*|snd_soc_cs[0-9]*|snd_soc_sdw_utils|\
    snd_acp_sdw_*|snd_ps_sdw_dma|snd_pci_ps|snd_sof_amd_*|snd_amd_sdw_acpi|\
    soundwire_amd|soundwire_generic_allocation) return 0 ;;
    *) return 1 ;;
  esac
}
# codecs are still listed so they can be loaded back explicitly below
CODECS=()
while read -r m; do [ -n "$m" ] && CODECS+=("$m"); done < <(
  lsmod | awk '$1 ~ /^snd_soc_(rt[0-9]+|tas[0-9]+|cs[0-9]+)/ { print $1 }'
)
for pass in 1 2 3 4 5 6 7 8; do
  removed=0 left=""
  while read -r m refs _; do
    is_stack_module "$m" || continue
    if [ "$refs" = 0 ]; then
      if modprobe -r "$m" 2>>"$LOG"; then removed=$((removed+1)); else left="$left $m"; fi
    else
      left="$left $m($refs)"
    fi
  done < <(lsmod | awk 'NR>1 { print $1, $3 }')
  [ -z "$left" ] && { log "recover: stack descarregada em $pass passe(s)"; break; }
  [ "$removed" = 0 ] && { log "recover: rmmod estagnou no passe $pass - ficaram:$left"; break; }
done
sleep 2
for m in snd_pci_ps ${CODECS[@]+"${CODECS[@]}"} snd_soc_rt721_sdca snd_soc_tas2783_sdw \
         snd_ps_sdw_dma snd_acp_sdw_legacy_mach; do
  modprobe "$m" 2>>"$LOG" || log "modprobe $m FALHOU"
done
sleep 2
is_bound || { echo "$PCI" > "$DRV/bind" 2>>"$LOG"; log "bind manual pos-reload"; }

# wait for enumeration/attach (up to 20 s)
for i in $(seq 1 40); do sleep 0.5; px13_sdw_all_attached && break; done
log "recover pos-reload:$(px13_sdw_status_str)"
px13_sdw_all_attached || log "recover: codecs seguem fora - audio interno indisponivel (reboot); BT/HDMI liberados pelo restart abaixo"

# Restart the session's PipeWire (stopped in release_card): a vanished
# SoundWire card leaves the WirePlumber graph wedged and takes Bluetooth audio
# down with it. One 'start' for everything - 'start sockets' followed by
# 'restart services' bounced PipeWire twice and confused the portal/bar.
if [ -S "$RT/bus" ]; then
  ru systemctl --user start pipewire.socket pipewire-pulse.socket \
                            wireplumber pipewire pipewire-pulse
  sleep 4
  if px13_sdw_all_attached; then
    CARD="$(px13_pw_card_as ru)"
    [ -n "${CARD:-}" ] && { ru pactl set-card-profile "$CARD" HiFi; sleep 1; }
    SINK="$(px13_pw_speaker_sink_as ru)" || SINK=""
    if [ -n "$SINK" ]; then
      ru pactl set-sink-mute "$SINK" 0
      # only take the default if nobody better holds it (never steal from BT)
      DEF="$(ru pactl get-default-sink 2>/dev/null)"
      case "${DEF:-}" in ""|auto_null) ru pactl set-default-sink "$SINK" ;; esac
      log "recover: SUCESSO - pipewire reiniciado, HiFi/speaker de volta (card=${CARD:-?} sink=$SINK default=${DEF:-vazio})"
    else
      log "recover: bus OK mas nenhum sink SoundWire no pipewire"
    fi
  else
    log "recover: pipewire reiniciado sem speaker interno"
  fi
  # Chromium keeps a dead PulseAudio socket after the restart and lists zero
  # audio devices ("no microphone" in Meet). Its audio service respawns.
  PIDS="$(px13_restart_browser_audio_services "$UNAME")"
  [ -n "${PIDS:-}" ] && log "recover: browser audio service(s) restarted (pids: $PIDS) so the mic is listed again"
else
  log "AVISO: $RT/bus ausente - pipewire nao reiniciado"
fi
exit 0
