# Surface Pro 11 7.2.5 v8 qualification checkpoint

Recorded: 2026-10-04. Status: **experimental, bounded ordinary-use checks passed;
not final beta/stable or upstream acceptance**.

This report records the exact combined X1E/OLED trial and the additional
coordinated camera/audio checks. It does not transfer qualification from an
older kernel, certify every camera mode or device, or replace historical test
records and ADRs.

## Exact candidate and recovery boundary

| Item | Recorded identity |
| --- | --- |
| Tested device | Surface Pro 11, Snapdragon X Elite / OLED, `microsoft,denali` |
| Installed ABI | `7.2.5-jg-0sp11v8-qcom-x1e` |
| Kernel source | [`8ba2b75713feb5c72bbc11dd8cce4048e23cdeea`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/8ba2b75713feb5c72bbc11dd8cce4048e23cdeea) |
| Source tree | `7a2c8655035c1f78774d114f294c3db67b2c9c62` |
| Upstream baseline | [`e57ec2987d4540fa89280d349f79c4d9bcd7cf27`](https://github.com/jglathe/linux_ms_dev_kit/commit/e57ec2987d4540fa89280d349f79c4d9bcd7cf27), Linux 7.2.5 |
| Build/install CLI | Lexr `0.5.0-rc.5`, `b74247d08f7c` |
| DTB delivery | `external-required`; same-build exact-ABI Denali DTBs and boot-support package, not embedded Stubble |
| Recovery/default | `7.2.0-jg-0sp11v23-qcom-x1e`, retained as the verified configured/effective default and fallback |

The [v8 experimental release](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-qcom-x1e-7.2.5-jg-0sp11v8)
contains the tested packages, manifests, checksums and corresponding source.
It is the **7.2.5 v8** candidate, not the historical 7.2.2 v8 trial. It does not
replace the v23 live-image set or claim a new v8 ISO. Its manifest remains
`experimental: true`, `hardware_qualified: false`.

These checks did not alter kernel source, userspace, boot defaults or package
configuration. Temporary diagnostics were removed; no additional diagnostic
test harness was added to the shipping kernel.

## Results and their limits

| Check | Result on this candidate | What it does not establish |
| --- | --- | --- |
| Camera preview, close/reopen and indicator | Human reports stable preview and correct indicator; three additional observed active-to-suspended cycles in Power Saver | Every capture format, RAW-buffer layout, control, crop, failed-start or suspend path |
| Concurrent quiet playback and camera | Human reports stable sound; playback was running in all 47 sensor-active samples | Recording/playback coexistence, loss-free frames, long soak or all graph lifetimes |
| Speakers, physical volume buttons, notifications and microphones | Combined v8 ordinary-use checklist reported working without the earlier lingering static | Measured microphone channel order/levels or physical amplifier/calibration/thermal safety certification |
| Protected-playback software path | Observed successful configure, nested protection-enable and same-graph start returns | A newly transmitted DSP start command, physical feedback health, or graph-stop/error coverage |
| Power profiles | Ordinary-use report passed; native low-power/Power Saver and all three CPU-policy caps independently observed | Every transition, fan response, policy hotplug, fault or teardown path |
| Battery/charger | User reports charging from 9% to 97%; near-full samples report Charging and USB online; earlier combined indicator checklist passed | Net charge in the near-full window, discharge rate, endurance or every supplier lifecycle |
| Touch, pen, Wi-Fi and ordinary USB | Combined ordinary-use checklist reported working | Every GPI client, recovery/concurrency path, X1P/LCD acceptance or USB4 tunnelling |

### Coordinated camera/playback observation

The successful retry ran from **14:05:57 to 14:11:39 UTC on October 4**. All
150 samples reported Power Saver and native `low-power`; the three CPU-policy
maximum frequencies remained 2,188,800 kHz. There were three camera-active
intervals, 47 sensor-active samples and 83 playback-running samples. Playback
was running in every sampled camera-active period. The sensor ended runtime-PM
suspended and the playback PCM ended closed.

Each of the three CAMSS stop snapshots reported **ECC=0, CRC=0 and zero VFE
violation, overflow and image-violation values**. These are snapshots, not
per-stream counter deltas or proof of error-free frames throughout the run.

The exact candidate's CSID680 definitions identify the last stop's `0x2000`
TOP and `0x4000` BUF_DONE values as completion indications. RDI values `0xcc0`
and `0xee8` include frame-boundary and `INFO_FRAME_DROP` flags; no zero-drop
claim is made. RX status `0x17` remains undecoded in the available CSID680
definitions. The logged enabled write-client configuration precedes its stop
write and does not alone demonstrate a leaked stream. The 4,800-byte stride
and 12,672,000-byte frame increment are consistent with aligned 3840x2640
RAW10 arithmetic, not validation of captured pixel buffers.

The user explicitly reported that preview and sound were stable and the
indicator behaved as expected. The raw metadata corroborates the activity and
normal end states. No images, video, microphone samples or audio content were
collected. This bounded three-cycle check passed and needs no repeat merely
to reproduce the same acceptance evidence.

### Preceding quiet-audio observation

The user confirmed normal sound through the built-in speakers. Temporary
owned probes observed this same-thread/same-graph order:

`configure entry -> nested protection enable(true) return 0 -> configure return 0 -> graph start return 0`

The exact source places that true-enable call on the successful configuration
path. All recorded probe-return miss counts and per-CPU trace loss counters
were zero, and the owned probes/instance were removed. The trace window was
90.009 seconds, but playback startup occurred about 56.746 seconds into it:
**only about 33.263 seconds after startup were traced**, not 90 seconds of
continuous playback. A successful graph-start return does not prove a new DSP
command was sent, because the source can reuse an already-started graph.

OpenCode Zai-Codex / GLM 5.1 reviewed the supplied exact-source definitions and
receipts and agreed with the bounded camera/audio pass. That is an advisory
review, not independent hardware execution, contributor certification or
maintainer acceptance. Earlier idle captures made while the desktop was locked
are not substituted for the successful retries.

## Userspace and diagnostic caveats

The trial retained its established FullIO v19c audio topology/UCM, IPTSD 3.1.0
integration, IMX681 libcamera packages and power-profiles service. It did not
replace userspace to clear diagnostic warnings.

Lexr's installed catalogue does not yet qualify the 7.2.5/SP11 v8 component
pairings. Unsupported/unverified catalogue results remain recorded; a passing
hardware observation is not authority to broaden compatibility automatically.
The inspected FullIO UCM dispatcher also lacked an explicit SP11 branch;
existing variant/custom files were present, but that inventory did not prove
the precise active route or clean-install/fresh-session selection. Do not
copy an unverified routing workaround or replace a working setup solely to
make Doctor green. Track compatibility authority in
[Lexr #44](https://github.com/ooaklee/lexr.sh/issues/44) and the native-profile
pairing decision in [Lexr #45](https://github.com/ooaklee/lexr.sh/issues/45).

Bluetooth was not part of this checklist. AFFiNE mixed finger/pen-hover canvas
jumps remain an application-side lead: the local control grid was smooth,
which does not certify every application's pointer handling.

## Review queue and remaining decisions

The canonical combined acceptance record is
[kernel PR #68](https://github.com/ooaklee/linux_ms_dev_kit-sp11/pull/68).
The held review queue remains refresh #51; camera #56; TX #57; playback #58;
battery #59; native profiles #60; GPI #61; fork CI #62/#64/#66. USB4 #24 stays
separate. Old cumulative test vehicles remain closed as superseded, not merged.

Before fork beta/stable promotion:

1. Complete and disposition the targeted source, buffer-layout and
   error/lifecycle acceptance items already recorded on #68. Ordinary-use
   success is not the entire acceptance checklist. Distinguish necessary
   correctness evidence from optional tuning; do not turn every future camera
   mode or endurance feature into a new implicit gate.
2. Clarify the supporting provenance/rights basis for the 13 retained
   geoca-authored ports with Leon's submitter sign-off. Missing author-matching
   sign-offs alone do not establish a licensing violation. Preserve author
   credit and source mapping; never invent certification or blanket-relicense.
3. Record explicit acceptance or follow-up for intentional deviations. The
   **two additional GPI corrections are already deferred** in
   [OE #67](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/67), without
   changing tested v8 source. Their generic-path residual risks remain; Denali
   QSPI guards do not exclude the device's other GPI channels. The separate
   intermediate-width portability proposal needs its own disposition.
4. Complete the reviewed fork-only CI rollout using workflow-write access.
   Earlier sparse hosted checks omitted checkpatch support tables and are not
   retroactively complete. Local complete-input results remain separate.
5. Recheck upstream, accept one exact composition, verify its tree, and protect
   beta plus the new `sp11/ubuntu-qcom-x1e-7.2.y` stable branch before changing
   the default. Do not merge every cumulative test PR or replay repairs twice.

For later focused upstream submissions, preserve dependencies and authors:
TX before playback; battery before profiles; shared source prerequisites before
their consumers. The maintainer's non-SP11 X1E boot check remains necessary
before shared audio reaches their release line. The fork-specific integration
workflow, scripts and policy must **not** be exported upstream.

The existing [camera follow-up #54](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/54)
still owns extended controls, calibration, failed-start privacy and resilience.
This check does not close its broader checklist. The known deep-resume
limitation in [#39](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/39)
is not declared fixed; no unattended suspend test is requested. X1P/LCD and
other Snapdragon X devices are not qualified by this X1E/OLED report.

## What the tester needs to do next

No repeat of the completed ordinary-use or coordinated camera/audio checklist
is requested. Keep v23 and recovery media available. The immediate user inputs
are workflow-write access, existing supporting contributor provenance, and
review of the remaining documented deviations/dispositions. Further hardware
checks, if needed after source review, require a separate bounded supervised
plan; do not begin suspend, fault injection or uncontrolled speaker tests.

Related context: [OE parity tracker #33](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/33),
[earlier v1 report #62](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/62),
and [upstream coordination #79](https://github.com/jglathe/linux_ms_dev_kit/pull/79).
Historical [camera design ADR0065](adr/adr-0065-sp11-front-camera-cphy-integration.md),
[processing ADR0066](adr/adr-0066-sp11-imx681-libcamera-simple-ipa.md) and
[audio strategy ADR0064](adr/adr-0064-sp11-audio-release-strategy.md) retain their
original scope; this checkpoint adds evidence rather than rewriting them.
