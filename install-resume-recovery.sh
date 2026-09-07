#!/usr/bin/env bash
# Installs the s2idle recovery FALLBACK: sleep hook + recovery script +
# detection helper. With the DKMS modules from install-durable.sh the amps
# recover on their own; the hook only reloads the stack when the driver
# reports a failure (PX13_RECOVER_POLICY=auto in /etc/px13-audio-fix.conf;
# always = old unconditional behaviour, never = disabled).
#
#   bash install-resume-recovery.sh            # install and dry-run the reload once
#   bash install-resume-recovery.sh --no-test  # install only
#   sudo bash install-resume-recovery.sh       # also fine ($SUDO_USER's session
#                                              # is used for the sound test)
#
# Nothing here is tied to one PX13 SKU; the PCI address and the PipeWire names
# are probed at runtime (and cached in /etc/px13-audio-fix.conf for the case
# where the card has already vanished from /proc/asound).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/px13-detect.sh
. "$REPO/lib/px13-detect.sh"

HOOK=/usr/lib/systemd/system-sleep/50-px13-soundwire
RECOVER=/usr/local/lib/px13-soundwire-recover.sh
DETECT=/usr/local/lib/px13-audio-detect.sh
DO_TEST=1
[ "${1:-}" = "--no-test" ] && DO_TEST=0

fail() { echo; echo "FAILED: $*" >&2; exit 1; }

px13_init_privs || fail "started as root with no desktop session to fall back to.
    Run it as your normal user (it sudos itself), or:
      sudo PX13_USER=<youruser> bash install-resume-recovery.sh"
root_run() { px13_root_run "$@"; }
asuser()   { px13_asuser "$@"; }

echo "==> 1/3 Detection helper and cache (needs root)"
root_run install -Dm644 "$REPO/lib/px13-detect.sh" "$DETECT"
PCI="$(px13_acp_pci)" || PCI=""
LONG=""
if CARD="$(px13_find_card)"; then LONG="$(px13_card_longname "$CARD" || true)"; fi
[ -n "$PCI" ] || fail "no ACP PCI device found - is the audio stack loaded?"
POLICY="$(px13_cache_get PX13_RECOVER_POLICY 2>/dev/null || true)"
px13_write_cache "$PCI" "$LONG" "${POLICY:-auto}" | root_run tee /etc/px13-audio-fix.conf >/dev/null
echo "    ACP PCI=$PCI  longname=${LONG:-?}  policy=${POLICY:-auto}"

echo "==> 2/3 Recovery script and sleep hook"
root_run install -Dm755 "$REPO/px13-soundwire-recover.sh" "$RECOVER"
root_run install -Dm755 "$REPO/50-px13-soundwire" "$HOOK"
root_run rm -f "$RECOVER".bak-*
echo "    $RECOVER"
echo "    $HOOK"

if [ "$DO_TEST" = 0 ]; then
  echo "==> 3/3 Skipping the dry run (--no-test)"
  exit 0
fi

echo "==> 3/3 Dry run: forcing the full reload once (policy=always; ~30 s, audio drops out)"
echo "    before:$(px13_sdw_status_str)"
root_run env PX13_RECOVER_POLICY=always "$RECOVER"
echo "    after :$(px13_sdw_status_str)"
echo "    --- log ---"
root_run tail -n 6 /var/log/px13-soundwire-resume.log 2>/dev/null | sed 's/^/    /' || true

sleep 2
if px13_session_ok && SINK="$(px13_pw_speaker_sink_as asuser)"; then
  echo "    playing a test sound on $SINK"
  asuser paplay --device="$SINK" /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || true
else
  echo "    (no session bus reachable - play something yourself to confirm)"
fi
echo
echo "Heard the test sound and every peripheral says Attached? The hook is validated."
echo "Final check: close and reopen the lid, then play something."
echo "Log: /var/log/px13-soundwire-resume.log"
