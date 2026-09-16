# TAS2783 speakers on the ASUS ProArt PX13 (HN7306) under Linux

Working **stereo** on the internal speakers of the ASUS ProArt PX13 (HN7306*,
AMD Strix Halo) — on a **stock kernel ≥ 7.1**, surviving kernel and
alsa-ucm-conf updates.

**Kernel 7.2 users:** the DKMS module had to be rebased — upstream changed
`sdca_parse_function()` and the old source no longer compiled, so the build
failed and the *stock* driver silently took over (stereo gone). Pull and re-run
`bash install-durable.sh`, then `bash check-audio.sh`. Details in
[Kernel updates](#kernel-updates-what-breaks-and-how-to-tell).

**Every SKU.** Nothing is hardcoded to one machine: the ALSA card index, the
card long name, the ACP PCI address and the PipeWire node names are all probed
at install time (`lib/px13-detect.sh`), and the installer now **fails loudly**
instead of exiting 0 without sound. See
[SKU independence](#sku-independence-why-it-used-to-break-on-other-px13s).

Tested on CachyOS `linux-cachyos` 7.1.3, 7.1.8 and 7.2.2 (HN7306EAC) and
reported working on HN7306EA / HN7306EA-LX005X. The module also compiles
against 7.3-rc1. Should work on Arch, Fedora and other distros with minor path
adjustments — the build follows whatever toolchain the target kernel was built
with (clang on CachyOS, gcc on Arch stock and Fedora), so no manual `LLVM=1`.

> **On kernels < 7.1** the tas2783 driver in mainline was not usable and the
> fix was a patched kernel (nealstar's 16-patch series, packaged for CachyOS
> as `linux-cachyos-px13` + `asus-proart-px13-quirks`). That method still
> works but requires a kernel rebuild on every update. The original guide and
> patch set are kept in [`patches/`](patches/) for reference. Everything
> below is for **stock kernels ≥ 7.1**.

---

> **This is a fork** of [ftoleedo/px13-audio-fix](https://github.com/ftoleedo/px13-audio-fix)
> — all the original work and the hard diagnosis is theirs. It adds, on top of
> upstream:
>
> - a **stock-Arch 7.1.9 port** of the DKMS module: `sdca_parse_function()` and
>   `sdw_slave_wait_for_init()` are probed from the target kernel's headers at
>   build time, because trees sharing a `LINUX_VERSION_CODE` do not share those
>   signatures;
> - a fix for a **hard freeze on resume** the recovery script itself could
>   cause (see [§5](#5-the-recovery-itself-could-freeze-the-machine-fixed-2026-09-05));
> - `install-oops-panic.sh`, optional hardening so a kernel oops reboots
>   instead of hanging.
>
> Pull upstream's fixes with `git pull upstream main`.

## TL;DR — what is broken on stock ≥ 7.1 and how this repo fixes it

TI upstreamed a new tas2783 driver in Linux 7.1 (it is **not** nealstar's
series). On the PX13 two problems remain:

| # | Problem | Symptom | Fix in this repo |
|---|---------|---------|------------------|
| 1 | **On 7.1:** the machine driver does not tag the card with `spk:tas2783`, so `alsa-ucm-conf` never creates the Speaker device. **On 7.2** the kernel *does* emit the tag — but `alsa-ucm-conf` ships nothing for tas2783, so UCM now tries to load a `sof-soundwire/tas2783.conf` that does not exist | 7.1: no sound / "Dummy Output" / only pro-audio. 7.2: the card's UCM fails to open outright (`failed to import hw:1 use case configuration -2`) | The three UCM files in `configs/` (they are what `alsa-ucm-conf` is missing) plus the **long-name override** that pulls in the codec init |
| 2 | The driver initializes **both** amps with DSP cluster index `0x01` (the ASUS ACPI tables carry no usable SDCA/DisCo function data, so the driver falls back to a static init sequence) | Mono from **one** speaker — which one can change between boots — or a phantom "center" image | Small **DKMS module** (stock driver + channel-selection control) + UCM setting `Left`/`Right` per amp |
| 3 | s2idle power-gates the ACP; the amps come back `Attached` but have lost all register and DSP state, and the stock driver (a) syncs a **stale regcache** back before re-initialising, so later power-up writes are skipped, (b) never powers the Function up on a re-prepared stream, (c) never re-prepares the SoundWire ports on `SNDRV_PCM_IOCTL_RESUME`, and (d) gives the firmware re-download 3 s, which times out after long sleeps | Speakers silent after suspend while every mixer level looks fine; sometimes `fw request, wait_event timeout` / `Update Slave status failed` in dmesg | The four kernel-7.3 fixes backported into the two **DKMS modules** (codec + `sdw_utils`), plus firmware kept in memory and a bounded retry. A detached `systemd-sleep` hook stays as a **health-checked fallback** ([details](#suspendresume-s2idle-recovery)) |

Bug #2 is **not** fixed in 7.2 or 7.3-rc1 either (same fallback init, still no
channel control upstream). The one-speaker report in
[CachyOS/linux-cachyos#737](https://github.com/CachyOS/linux-cachyos/issues/737)
on kernel 7.1.1 is exactly this.

Firmware note: `linux-firmware ≥ 20260519` ships the amp firmware as
`ti/audio/tas2783/1714-1-0x8.bin` / `1714-1-0xB.bin` — **no more extracting
blobs from the Windows driver**.

---

## Quick install

```bash
git clone https://github.com/leepaulmann/px13-audio-fix.git && cd px13-audio-fix
bash install-durable.sh        # asks for sudo when needed
bash install-resume-recovery.sh   # survive suspend/resume
bash install-oops-panic.sh        # optional: reboot on oops instead of freeze
# then reload the whole SoundWire stack once (or reboot):
sudo PX13_RECOVER_POLICY=always bash test-sdw-module-reload.sh
```

`sudo bash install-durable.sh` works too: the installer needs root for the
module and the UCM files but must **not** be root for the PipeWire half
(`systemctl --user` does not exist for root), so when started under sudo it
drops back to `$SUDO_USER` for those steps. If it cannot find a session to drop
back to it says so instead of half-failing (`sudo PX13_USER=<you> bash ...`).

The script:

0. **Probes** the card index, the ALSA driver name and the `CardLongName`, and
   aborts with a diagnostic if there is no SoundWire card or no TAS2783 amp.
1. Installs the patched `snd-soc-tas2783-sdw` module via **DKMS**
   (auto-rebuilds on every kernel update) — falls back to a manual build
   into `/lib/modules/$(uname -r)/updates/` if dkms is not installed.
2. Installs the three UCM files under the long name **of your machine**, and
   removes any override this repo previously installed under a different SKU
   name (dead weight — UCM never reads it).
3. **Verifies** that UCM now exposes a `Speaker` device and exits non-zero with
   diagnostics if it does not. No more silent success.
4. Restarts PipeWire, selects the HiFi profile, checks the SoundWire
   peripherals, saves the ALSA state.

The suspend/resume recovery is a separate, optional step:

```bash
bash install-resume-recovery.sh        # hook + recovery script + dry run
```

---

## SKU independence (why it used to break on other PX13s)

The first version of this repo hardcoded four machine-specific values. Three of
them were cosmetic; one silently broke every laptop that was not the machine it
was written on:

| Hardcoded | Actually varies with | Symptom when wrong |
|---|---|---|
| `LONG=ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC` | **the SKU** (DMI product name) | **silent total failure** |
| `CARD=1` | boot order / other sound cards | wrong card poked |
| `alsa_card.pci-0000_c4_00.5-platform-amd_sdw` | ACP PCI address | profile switch fails |
| `PCI=0000:c4:00.5` | ACP PCI address | resume recovery does nothing |

The first one is fatal because of how ALSA UCM resolves configs
(`/usr/share/alsa/ucm2/ucm.conf`):

```
conf.d/${CardDriver}/${CardLongName}.conf     <- probed first
conf.d/${CardDriver}/${CardDriver}.conf       <- package-owned fallback
```

`CardLongName` is built from DMI, so it differs per SKU:

```
ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC    128 GB / GOPRO
ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EA-1.0-HN7306EA      64 GB, LX005X, ...
```

An override installed under the wrong name is **never read**. UCM falls back to
the stock config, the HiFi profile has no Speaker device, PipeWire shows a
dummy sink — and the old installer still printed its steps and exited 0.

Check yours with:

```bash
amixer -c "$(cat /proc/asound/cards | grep -i soundwire | awk '{print $1}')" info
#   Card sysdefault:1 'amdsoundwire'/'<-- this string is the long name -->'
```

Since then everything is probed at runtime and the installer refuses to finish
without a working Speaker device. Found by **@jamescutts** (silent failure on a
64 GB HN7306EA), pinpointed to that variable by **@dmicheel** (who hit it on a
non-GOPRO HN7306EA-LX005X too) and confirmed by **@DevGrishin**, in
[CachyOS/linux-cachyos#737](https://github.com/CachyOS/linux-cachyos/issues/737).

---

## Kernel updates: what breaks, and how to tell

The DKMS module is a copy of the upstream driver plus one control, so it rides
on an API that moves. Three times now an update has degraded the audio **silently**:

| Kernel | What changed | What you saw |
|---|---|---|
| 7.2 | `sdca_parse_function()` gained a `struct sdw_slave *` parameter | DKMS build failed during the pacman transaction, the **stock** module loaded instead, `Channel Playback` disappeared → mono from one speaker |
| 7.3-rc1 | the same function *lost* that parameter again | same, if built from the 7.2 source |
| distro 7.2.y with 7.3 backports (`linux-omarchy` 7.2.5-3) | the 7.3 SDCA/`sdw_utils` API under a **7.2 version code**: the module's `>= 7.3` check picked the old call, and the series-pinned `sdw_utils` package tried to build Arch 7.2.3 sources there | both DKMS builds failed in the transaction; the stock driver brought the resume fixes but no `Channel Playback`, so the **right speaker was silent even on a cold boot**. Fixed by probing the header instead of the version, and by pinning `sdw_utils` to the kernel flavour too |
| 7.2 | the kernel started tagging the card `spk:tas2783` — while `alsa-ucm-conf` (1.2.16.1) still ships no tas2783 config | on a machine **without** this repo, worse than 7.1: UCM cannot open the card at all instead of silently skipping the Speaker device |
| (any) | a driver swap under a live WirePlumber | the stored per-route volume can come back at **0%** — sink unmuted, HiFi active, `paplay` exits 0, and nothing comes out |
| new **series** (7.1 → 7.2) | the `sdw_utils` DKMS package is pinned to one kernel series and flavour (`BUILD_EXCLUSIVE_KERNEL`, e.g. `^7\.2\.[0-9]+-([0-9]+-)?arch[0-9.-]*$`), so DKMS skips it and the **stock** `snd_soc_sdw_utils` loads | a PCM that was open across suspend (the speaker always is) comes back running but silent, no error anywhere. Fix: `cd module-sdw-utils && ./fetch-sources.sh && bash ../install-durable.sh` |
| ≥ 7.3 (or a backport) | the resume fixes are in-tree, but **not** `Channel Playback`: the stock driver leaves amp2 on cluster 0x01 (Left) | the codec package is still required; the `sdw_utils` one is not. `install-durable.sh`, `fetch-sources.sh` and `check-audio.sh` detect the in-tree fix by disassembling `asoc_sdw_trigger` (it calls `sdw_prepare_stream`), not by version |

Nothing logs an error for any of these. Two tools catch them — **before** the
reboot, the gate builds everything against every installed kernel (a kernel
update installs the new headers first, so this sees the kernel you are about
to boot):

```bash
./.gate          # exit 1 on any build error/warning or a kernel with no sdw_utils fix
```

It was checked against the pre-fix module and fails on `linux-omarchy` 7.2.5
with the same `too many arguments to function 'sdca_parse_function'` DKMS hit.
Taken from [ftoleedo/px13-audio-fix](https://github.com/ftoleedo/px13-audio-fix);
this fork adds the per-kernel `sdw_utils` check.

**After** the reboot, the checker:

```bash
bash check-audio.sh
```

It verifies the invariants — both patched modules in `updates/` (and the same
build in memory as on disk), DKMS built for the running kernel, both amps on
different channels, a speaker sink that is neither muted nor at 0%, each amp's
`fw_state` = `ok`, the recovery policy, and `kernel.panic_on_oops` — and prints
the exact command to fix each one. Run it after every kernel update; exit code
is non-zero if anything is off.

Verified on 7.2.2 by pointing `ALSA_CONFIG_UCM2` at a copy of the system tree:
with none of this repo's files, `alsaucm -c1 list _devices/HiFi` dies with
`could not open .../sof-soundwire/tas2783.conf`; with the two codec files but no
long-name override it dies with `variable '${var:SpeakerMixerElem}' is not
defined` (the base config's `If.spk` regex still does not list tas2783, so the
codec init is never included). All three files are still required on 7.2 — the
long-name override for a new reason.

The proper upstream fix for this half now belongs in **alsa-ucm-conf**, not the
kernel: a `sof-soundwire/tas2783.conf` and `codecs/tas2783/` upstream would
retire two of the three files here.

The module probes the target kernel's headers at build time for that call and
builds clean on 7.1.9-arch, 7.2, 7.3-rc1 and `linux-omarchy` 7.2.5. Upstream 7.2 also absorbed two of
the three original local patches (the `tas25xx_*_misc` stubs and the `0x`
firmware-name prefix). The local delta today is the `Channel Playback`
control, the three 7.3 resume fixes, and the `PX13:` hardening described in
[the kernel-side patch](#the-kernel-side-patch-module).

### Runbook for the next kernel update (written for 7.3)

This machine runs two kernels side by side: Arch `linux` (7.2.3-arch1-3,
both DKMS packages) and `linux-omarchy` (7.2.5-3-omarchy, codec package only -
its in-tree `sdw_utils` already has the RESUME fix). Either one can be the
rollback for the other from the limine menu.

**Before rebooting** into a new kernel (the update installs its headers first):

```bash
./.gate          # module + sdw_utils build on every installed kernel
dkms status      # the codec package must say "installed" for the new kernel
```

**After rebooting:**

```bash
bash check-audio.sh                       # NOT under sudo - root cannot see PipeWire
speaker-test -D pulse -c2 -t wav -l1      # "Front Right" must come from the RIGHT speaker
sudo rtcwake -m no -s 30 && systemctl suspend   # plain rtcwake -m mem skips the sleep hook
speaker-test -D pulse -c2 -t wav -l1      # again, after the resume
tail -3 /var/log/px13-soundwire-resume.log      # expect "healthy, nothing to do"
# the rt721 jack codec must come back from runtime suspend:
timeout 3 pacat --playback --device="$(pactl list short sinks | awk '/Headphones/{print $2;exit}')" \
  --format=s16le --rate=48000 --channels=2 /dev/zero &
sleep 1.5; cat /sys/bus/soundwire/devices/sdw:*:025d:0721:*/power/runtime_status   # "active"
journalctl -k -b | grep -E 'rt721.*\(-61\)'   # must print nothing
```

Optional, when the recovery script or the module stack changed: a real full
reload, `sudo PX13_RECOVER_POLICY=always bash test-sdw-module-reload.sh`
(audio drops for ~15 s; it plays a chime at the end - listen for it). The log
must say `stack descarregada em N passe(s)` and no `FALHOU`/`estagnou`.

**What to expect on 7.3, and what to do if it goes wrong:**

| Expectation / risk | Symptom if it goes wrong | What to do |
|---|---|---|
| The **codec package is still required**: stock 7.3 has the resume fixes but no `Channel Playback`, and leaves amp2 on cluster 0x01 (Left) | right speaker silent, even on a cold boot; `check-audio` FAIL on "patched module" / "stereo channel" | `.gate` shows why the build failed. If the API moved again, add a header probe to `module/Makefile` like `HAVE_SDCA_PARSE_FUNCTION_NO_SDW` (never a `LINUX_VERSION_CODE` check - distro kernels backport), then `sudo dkms install --force snd-soc-tas2783-sdw-px13/1.1 -k <kernel>` after copying `module/` to `/usr/src/snd-soc-tas2783-sdw-px13-1.1/`, and reboot. Upstream's module 1.2 (rebased on the 7.3 driver) is the fallback source if ours cannot be made to build |
| The channel is re-applied after every re-init: upstream measured amp2 coming back on Left after s2idle on 7.3 | stereo on boot, mono after a suspend | the `PX13:` re-apply in `tas2783-sdw.c` covers it - if it stops working, check that `Channel Playback` still exists (`amixer -c1 controls`) and that the re-apply runs after the init sequence |
| The **`sdw_utils` package is skipped** (its `BUILD_EXCLUSIVE_KERNEL` only matches Arch 7.2.x); 7.3's in-tree module has the fix | DKMS prints an exclusion notice (exit 77) - that is expected, not an error | nothing. `check-audio` confirms the in-tree fix from the binary |
| **rt721 jack codec dies in runtime suspend** - seen upstream on 7.3.0-rc2, *not* on omarchy 7.2.5 | **no speaker sink at all**, the card only offers `off` / `pro-audio`; `-61` from rt721 in `journalctl -k`; `check-audio` FAIL "jack codec (rt721) alive" | install `configs/90-px13-rt721-no-autosuspend.rules` (steps inside the file), then a forced reload: `sudo PX13_RECOVER_POLICY=always /usr/local/lib/px13-soundwire-recover.sh` |
| The fallback's unload passes do not depend on module names (a 7.3 platform module like `snd_sof_amd_acp7x` is picked up) | `rmmod estagnou` in the resume log, codecs never re-probed | read the modules it lists; extend `is_stack_module()` in `px13-soundwire-recover.sh` only if a stack module has a new name pattern, then reinstall it to `/usr/local/lib/` |
| `SDW1-PIN4-CAPTURE-SmartAmp ... -22` (about 20 per boot and per reload) | log noise only - seen on 7.2.3 and 7.2.5 with working audio | ignore; not matched by the recovery's error filter |

**After the Arch 7.2.3 kernel is uninstalled**, the `sdw_utils` package has
nothing left to build for: `sudo dkms remove snd-soc-sdw-utils-px13/7.2.3 --all`
and `sudo rm -rf /usr/src/snd-soc-sdw-utils-px13-7.2.3` (and the stale
`-7.1.9` tree). If an Arch 7.2.y is still wanted, keep it - the package
rebuilds there on its own.

---

## Suspend/resume (s2idle) recovery

**Since 2026-09-07 the amps recover on their own.** The earlier reading of this
failure — "the slaves vanish from the bus and the firmware is wiped, so reload
everything" — was wrong about the first half: across 31 logged resumes on a
HN7306EA every slave was `Attached` before the recovery script did anything,
and the ALSA card index never changed. What the script saw as a vanished card
was the card it had just destroyed itself. The real damage is inside the amps:
when the ACP is power-gated (S0i3) the TAS2783 loses all register and DSP
state, re-attaches, and the stock driver then

1. **syncs a stale regcache** back before re-initialising, so the later DAPM
   power-up and PDE writes compare equal to the cache and never reach the
   hardware — playback runs, no error, silent speakers;
2. on a stream that is only **re-prepared** (not set up again) never powers
   the SDCA Function up, so the port never finishes channel preparation;
3. on `SNDRV_PCM_IOCTL_RESUME` — which PipeWire uses on a `SUSPENDED` PCM, and
   AMD ACP advertises — enables the SoundWire stream without re-preparing the
   ports (the speaker PCM is always open across suspend because of the
   WirePlumber no-suspend rule, the mic during a meeting);
4. gives the firmware re-download 3 s and, when that times out after a long
   sleep, leaves the amp without firmware for the rest of the session
   (`fw request, wait_event timeout` → `Update Slave status failed:-11`).

Andrey Golovko fixed 1–3 upstream in **Linux 7.3-rc1**, measured on a PX13
HN7306EAC (`b627da43035`, `119046319e77`, `0c7aeb0f5ece` in `tas2783-sdw.c`;
`6fd1b9225de1` in `sdw_utils`). Kernels < 7.3 do not have them, so this repo
carries them:

| Package | Contents |
|---|---|
| `module/` → `snd-soc-tas2783-sdw-px13` | the three codec fixes, plus (`PX13:` in the source) the firmware image kept in memory and replayed on re-init instead of going through the firmware loader, a bounded retry when re-init fails, the last `Channel Playback` / volumes re-applied after the init sequence (which would otherwise leave both amps on cluster `0x01` = mono and the digital volume at 0 dB), and `/sys/bus/soundwire/devices/sdw:*/fw_state` (`ok`, `no-fw`, `init-failed`, `unattached`) |
| `module-sdw-utils/` → `snd-soc-sdw-utils-px13` | the stock `snd_soc_sdw_utils` rebuilt from the running kernel's linux-stable tag (`fetch-sources.sh`) with the RESUME re-prepare fix; pinned to that kernel series with `BUILD_EXCLUSIVE_KERNEL` |

The audio outage after a healthy resume drops from ~20 s (reload + PipeWire
restart) to nothing, PipeWire is never restarted — so **Brave keeps its
microphone** — and the PCI teardown that could oops the kernel (section 5) does
not run.

### The fallback

The sleep hook stays installed, but it is now a health check first:

| File (repo) | Installed to | Purpose |
|---|---|---|
| `50-px13-soundwire` | `/usr/lib/systemd/system-sleep/` | post hook: dispatches the recovery as a transient unit (`systemd-run --no-block --collect`) and exits immediately — running it inline keeps the user session frozen (black screen) until it finishes |
| `px13-soundwire-recover.sh` | `/usr/local/lib/` | after a 10 s settle: `PX13_RECOVER_POLICY` **auto** (default) = reload only if a slave is missing, an amp's `fw_state` is not `ok`, or the kernel log since the last `PM: suspend exit` has a SoundWire/codec resume error; **always** = the old unconditional reload; **never** = log and exit. The reload: stop PipeWire (sockets too, or it respawns and holds `/dev/snd`) → unbind PCI → unload the stack children first → reload → wait for `Attached` → start PipeWire → HiFi profile, unmute, default sink only if nothing better holds it → restart Chromium/Electron audio services so browsers list the mic again |
| `lib/px13-detect.sh` | `/usr/local/lib/px13-audio-detect.sh` | the probes and the health helpers, shared by every script |
| — | `/etc/px13-audio-fix.conf` | cache of the ACP PCI address and long name, plus `PX13_RECOVER_POLICY` (editable) |
| `test-sdw-module-reload.sh` | — | the same reload interactively (`sudo`, forces `always`); also the way to activate a newer build of either module without a reboot |

Install it with `bash install-resume-recovery.sh` (its one-off dry run forces
`always`, so you see the reload work without suspending). Everything is logged
to `/var/log/px13-soundwire-resume.log`; a healthy resume logs one line
(`healthy, nothing to do (fw:... slaves:...)`).

Known case that still needs the fallback: after very long sleeps the RT721
headset codec has logged `Initialization not complete, timed out` / `PM: failed
to resume: error -110` (stock module, not rebuilt here). The health check sees
it in the journal and reloads.

### 5. The recovery itself could freeze the machine (fixed 2026-09-05)

Tearing the ACP down 2 s after `PM: suspend exit` — the old `sleep 2` in
`px13-soundwire-recover.sh` — races the driver's own teardown. On `7.1.9-arch1-2`
it landed in a corrupted resource tree:

```
BUG: kernel NULL pointer dereference, address: 0000000000000050
RIP: release_resource+0x34/0x80
  platform_device_del <- platform_device_unregister <- pci_device_remove
  <- device_release_driver_internal <- unbind_store
```

`release_resource()` holds the global `resource_lock` for **write**. The oops
killed the task with the lock still held (`exited with irqs disabled /
preempt_count 1`), so every subsequent GPU page fault —

```
amdgpu_gem_fault -> ttm_bo_vm_fault_reserved -> vmf_insert_pfn_prot
  -> pfnmap_setup_cachemode -> lookup_memtype -> pat_pagerange_is_ram
  -> walk_system_ram_range -> find_next_res -> queued_read_lock_slowpath
```

— spun on it forever. The desktop froze solid: keystrokes still registered,
then the first redraw wedged the compositor (`soft lockup - CPU#12 stuck for
26s! [quickshell:gl0]`). Only a power cycle cleared it. Roughly 1 resume in 10.

**The fix is the delay, not the method.** Dropping the sysfs unbind would not
help — `modprobe -r snd_pci_ps` runs the same `pci_device_remove` path. The
lever is *when* the teardown starts. On healthy resumes SoundWire
re-enumeration does not report in until ~t+7 s, so the settle is now:

```bash
sleep "${PX13_RESUME_SETTLE:-10}"
```

Raise `PX13_RESUME_SETTLE` if it ever recurs, rather than reaching for a
different teardown method.

With policy `auto` this teardown only runs when a resume actually failed, so
the exposure is now rare rather than every wake.

Pair it with `bash install-oops-panic.sh` (optional): a kernel oops then
reboots after 10 s instead of hanging, which is both kinder to use and what
makes the bug practical to chase — each hit becomes a logged oops rather than
a wedge. Note that the first version of that installer put `panic_on_oops=1`
on the kernel command line, which is **not** a kernel parameter (only the
sysctl is; the kernel logs the token as unknown and the setting stayed 0
after the reboot). It now uses `oops=panic` plus a `/etc/sysctl.d/` file and
verifies the live sysctl.

**Upstream status: unreported.** The crashing frames are all in-tree core code,
so it is a legitimate `snd_pci_ps` teardown bug — but the kernel is tainted
`G OE` by the DKMS module in `module/`, which is a modified copy of a driver in
the very stack being torn down. The trace shows where the corruption was
*detected*, not where it was *created*, so the honest first step is a repro with
the stock in-tree `snd-soc-tas2783-sdw` (DKMS keeps it under
`/var/lib/dkms/snd-soc-tas2783-sdw-px13/original_module/`). Reproduces
untainted → worth filing. Does not → the bug is in this repo's patch.

---

## What gets installed where

| File (repo) | Installed to | Purpose |
|---|---|---|
| `module/` | `/usr/src/snd-soc-tas2783-sdw-px13-1.1` (DKMS) | Stock 7.2.y tas2783 driver + `Channel Playback` control + the 7.3 resume fixes + `PX13:` hardening |
| `module-sdw-utils/` | `/usr/src/snd-soc-sdw-utils-px13-<kernel tag>` (DKMS, one kernel series and flavour) | Stock `snd_soc_sdw_utils` for the running kernel + the 7.3 RESUME re-prepare fix; `fetch-sources.sh` pulls the sources and generates `dkms.conf`. Skipped on kernels whose in-tree copy already has the fix |
| `configs/ucm-card-override.conf.in` | `/usr/share/alsa/ucm2/conf.d/<CardDriver>/<CardLongName>.conf` — **both probed**, template placeholders substituted at install time | Forces the speaker codec; **unowned by any package** → survives `alsa-ucm-conf` updates |
| `lib/px13-detect.sh` | `/usr/local/lib/px13-audio-detect.sh` | Runtime probes: card, driver, long name, amp count, ACP PCI, PipeWire names |
| `check-audio.sh` | — | Post-update health check; non-zero exit if any invariant broke |
| `configs/90-px13-rt721-no-autosuspend.rules` | `/etc/udev/rules.d/` — **only by hand**, when needed | Keeps the rt721 jack codec out of runtime suspend (upstream 7.3.0-rc2 failure; not needed on omarchy 7.2.5) |
| `.gate` | — | Pre-reboot check: module and `sdw_utils` build on every installed kernel, scripts parse |
| `configs/sof-soundwire_tas2783.conf` | `/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` | Speaker device for the HiFi profile; sets `tas2783-1 = Left`, `tas2783-2 = Right` on every profile activation (guarded on the **second** amp existing, so a single-amp variant still gets a mono Speaker instead of a broken profile) |
| `configs/codecs_tas2783_init.conf` | `/usr/share/alsa/ucm2/codecs/tas2783/init.conf` | Volume-control remap (supports both driver generations) |
| `50-px13-soundwire` | `/usr/lib/systemd/system-sleep/` | Health-checked fallback after s2idle (`PX13_RECOVER_POLICY` in `/etc/px13-audio-fix.conf`) |
| `configs/99-echo-cancel.conf` | `~/.config/pipewire/pipewire.conf.d/` | Optional: echo-cancelled mic source for calls |
| `configs/51-amd-sdw-channels.conf` | `~/.config/wireplumber/wireplumber.conf.d/` | Optional: FL/FR channel positions on the speaker node |
| `configs/oops-panic.conf`, `configs/99-px13-oops-panic.conf` | `/etc/limine-entry-tool.d/` (limine only), `/etc/sysctl.d/` | Optional: `oops=panic panic=10` on the cmdline and `kernel.panic_on_oops=1` via sysctl so a kernel oops reboots instead of freezing — install with `bash install-oops-panic.sh`, which falls back to printing GRUB/systemd-boot instructions on other bootloaders |

### The kernel-side patch (module/)

The DKMS module is the stock `linux-7.2.y` `tas2783-sdw.c` plus:

- nealstar's channel-selection control rebased onto the upstream driver:

  ```
  tas2783-N Channel Playback : enum { Off, Left, Right }
  ```

  It writes the SDCA control `PPU21 / UDMPU CLUSTERINDEX` (values `0 / 1 / 4`),
  which tells each amp's DSP which channel of the stereo stream to render.
  Without it both amps stay at the boot value `0x01` written by
  `tas2783_init_seq`.
- the three 7.3-rc1 resume fixes (see the s2idle section), applied by hand and
  labelled with their upstream commit ids in the source;
- `PX13:`-labelled hardening: firmware image retained in memory and replayed on
  re-init (`tas2783_fw_download()`), a mutex-serialised bounded retry
  (`tas2783_init_work`), user-set channel/volume values restored after the init
  sequence (`tas_restore_user_state()`), and the `fw_state` sysfs attribute;
- build-time probes of the target kernel's headers for the two SDCA/SoundWire
  calls whose signatures differ between trees.

---

## Verifying

```bash
uname -r                                   # stock kernel, >= 7.1
modinfo -k $(uname -r) snd_soc_tas2783_sdw -F filename
#   -> .../updates/... (the DKMS/patched module, not .../kernel/sound/...)

C=$(awk '/soundwire/ && /^ *[0-9]+ \[/ {print $1; exit}' /proc/asound/cards)
alsaucm -c "$C" list _devices/HiFi | grep Speaker      # must print "Speaker"
amixer -D "hw:$C" cget name='tas2783-1 Channel Playback'   # values=1 (Left)
amixer -D "hw:$C" cget name='tas2783-2 Channel Playback'   # values=2 (Right)

pactl list cards | grep "Active Profile"   # HiFi
speaker-test -D pulse -c2 -l1 -t wav       # voice L/R from the correct side
```

If the sides are physically swapped, exchange the two `cset` values in
`/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` and restart PipeWire.

---

## Troubleshooting

- **"Dummy output" / no Speaker device** — the long-name override is missing or
  installed under another SKU's name. `bash install-durable.sh` now detects the
  right name and refuses to finish without a Speaker device; if you are fixing
  it by hand, compare `amixer -c <card> info` (the string after the `/`) with
  the file names in `/usr/share/alsa/ucm2/conf.d/amd-soundwire/`. As a last
  resort you can force it: `PX13_LONGNAME='<name>' bash install-durable.sh`.
- **Mono / one speaker only, right after a kernel update** — the DKMS build
  failed and the stock module took over. `bash check-audio.sh` says so in one
  line; `dkms status` and
  `/var/lib/dkms/snd-soc-tas2783-sdw-px13/1.1/build/make.log` say why (`./.gate`
  shows it for every installed kernel). If the
  driver API moved again, the module source needs a rebase (see
  [Kernel updates](#kernel-updates-what-breaks-and-how-to-tell)); otherwise
  `bash install-durable.sh` is enough. Without dkms: `cd module && make` then
  reinstall — the Makefile picks the right toolchain on its own.
- **Everything looks right and nothing comes out** (sink unmuted, HiFi active,
  `paplay` exits 0, `speaker-test` runs) — check the **volume**, not the mute:
  `pactl get-sink-volume <speaker sink>`. WirePlumber persists a per-route
  volume, and a driver swap under it can bring it back at `0% / -inf dB`. The
  installer now raises a 0% speaker sink to 60%; `bash check-audio.sh` flags
  it.
- **Right speaker silent on a distro kernel whose version looks old** (e.g.
  `linux-omarchy` 7.2.5) — the distro backported a newer SDCA API; see the
  [runbook](#runbook-for-the-next-kernel-update-written-for-73). Always probe
  headers, never trust `LINUX_VERSION_CODE`.
- **No speaker sink at all, card offers only `off` / `pro-audio`** — first
  check the rt721 jack codec: `journalctl -k -b | grep 'rt721.*(-61)'`. If
  it prints anything, install `configs/90-px13-rt721-no-autosuspend.rules`
  and force a reload (see the runbook table).
- **Failed DKMS build messages for `snd-soc-sdw-utils-px13` during a kernel
  update** — expected to be an exclusion notice (exit 77) on kernels that do
  not need it. A real build *error* there means `BUILD_EXCLUSIVE_KERNEL`
  matched a kernel it should not have; regenerate `dkms.conf` with
  `KVER=<the kernel it is for> module-sdw-utils/fetch-sources.sh` and copy it
  to `/usr/src/snd-soc-sdw-utils-px13-<ver>/`.
- **Sound goes to pro-audio profile / "Invalid argument"** — switch profile:
  `pactl set-card-profile "$(pactl list short cards | awk '/sdw/{print $2;exit}')" HiFi`.
- **Dead after suspend** — `bash install-resume-recovery.sh`; recover
  immediately with `sudo /usr/local/lib/px13-soundwire-recover.sh` or
  `sudo ./test-sdw-module-reload.sh`.
- **Silent speakers although *everything* looks right** (sink default and
  unmuted, HiFi active, `amixer` switches on) after a resume — that is the
  wiped TAS2783 firmware (`dmesg | grep 'without fw download'`). Same fix as
  above: full module reload; a rebind alone will not re-download it.
- **Bluetooth connects but plays nothing** after a resume — wedged WirePlumber
  graph: `systemctl --user restart wireplumber pipewire pipewire-pulse`. If
  the BT device then only offers headset (mono) profiles, disconnect and
  reconnect it to rediscover A2DP.
- **Audio jumps to Bluetooth after profile switch** — set the default sink
  once: `wpctl set-default <id of Audio Coprocessor Speaker>`.
- **`Failed to connect to user scope bus ... $DBUS_SESSION_BUS_ADDRESS and
  $XDG_RUNTIME_DIR not defined`** — you are on a version older than `ff53876`
  and ran the installer entirely as root. Pull and re-run; the system half is
  already installed, the script is idempotent.

---

## Upstream status

The proper fix belongs in the kernel: either the `Channel Playback` control
or an ACPI/platform quirk mapping each amp's SoundWire `unique_id` to a
channel, since the PX13's ACPI provides no usable SDCA function data
(`function type only supported as DisCo constant`). Until something lands,
this repo keeps working setups alive across updates. Progress is tracked in
[CachyOS/linux-cachyos#737](https://github.com/CachyOS/linux-cachyos/issues/737).

The s2idle state loss **is fixed upstream** in Linux 7.3-rc1 (Andrey Golovko,
`ASoC: tas2783-sdw: drop stale regcache on uninitialized re-attach` and
siblings; see the s2idle section). Until a ≥ 7.3 kernel is installed this
repo backports them. Still local: the firmware-in-memory replay and retry,
the user-state restore after re-init, and the `fw_state` attribute — worth
proposing upstream once they have some mileage. The `release_resource()` oops
in the old unconditional teardown (section 5) is unreported.

## Credits

- **nealstar** — original 16-patch series, including the channel-selection
  control this module carries.
- **fecet** — CachyOS packaging (`linux-cachyos-px13`,
  `asus-proart-px13-quirks`) for the < 7.1 era.
- **TI / Niranjan H Y, Baojun Xu, Kevin Lu** — upstream tas2783 driver.
- **jamescutts, dmicheel, DevGrishin** — found and pinpointed the silent
  SKU dependency (the UCM long name), which is what made this repo
  SKU-independent.

## License

Guide and scripts: CC0. Kernel module: GPL-2.0 (derived from the upstream
driver).
