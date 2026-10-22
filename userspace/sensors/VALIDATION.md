# Sensor source qualification boundary

## Before this OE publication

The exported production source bytes have prior native ARM64 software
evidence. This is not evidence of deployment on the Surface and does not
qualify arbitrary providers with the same version number.

| Component | Existing software evidence | Not established |
| --- | --- | --- |
| Pinned libqmi + downstream libssc | Fresh native build/private stage; versioned public ABI checks (83 retained + 14 new sample exports); normal CLI help/version; two installed-header public SDK consumers | Live sensor discovery/streaming, hardware placement, calibration, GIR/VAPI, legacy QRTR suite |
| Downstream proxy | Ordinary and ASan/UBSan client builds; 286 passed unit cases and one unavailable French-locale skip per build; 40 acquisition cases (18 input, 18 poll, 4 buffer); 57 ordinary Python and 22 sanitized SSC Claim selections passed without skips | Physical orientation/ALS/compass/proximity, deployment, automatic rotation, suspend/resume, full hardware parity |
| Calibration admission correction | Two isolated inverse controls rejected early sampling fixup and I/O-error-as-absence at their exact assertions; unmodified tests retained | Atomic hotplug snapshots or freshness of cached non-null GUdev attributes |

Provider and system DSOs were not sanitizer-instrumented. Six setup diagnostic
records in the earlier QMI/SSC composition were explicitly retained rather
than suppressed: QMI Python-module deprecation, `run_command(check:)` default
advice, a Meson minimum/feature mismatch, two diagnostic summaries and SSC's
redundant custom-buildtype settings. This is not a warning-free build claim
or a guarantee of Meson 2 compatibility.

CLI help/version checks are backed by the native runs and static inspection
of `libssc/source/src/libssc-cli.c`: option parsing handles help and the version
branch returns before sensor construction, discovery or the event loop. This
is not a general claim that other CLI arguments are firmware-free, nor a
system-call trace of every loaded dependency.

The earlier 49 SSC Claim test daemons have graceful SIGTERM-success evidence.
The ordinary proxy integration helper still uses its inherited kill-based
stop and temporary successful logs; it does not establish graceful production
shutdown or complete retained per-daemon diagnostics.

## Export checks

The public source export is compared file-by-file with the accepted snapshots,
including bytes, executable bits and six internal libqmi symlinks. All original
licences/notices remain. Private evidence manifests, absolute local patches,
build outputs, signing material, Windows payloads and live device captures
are not publication inputs. One upstream Android trace is explicitly omitted
from libssc; its original digest and reason remain in `libssc/SOURCE.json`.

`SOURCE.sha256` and each component's relative `SOURCE.json` make this
composition inspectable without private filesystem paths. They record source
identity, **not** authenticated release authority, a Lexr package schema or
tested kernel/OS support ranges.

## Initial exported-source check — 2026-10-20

A new isolated native ARM64 job checked the initial source publication at
`047c30bf4bca0d91141f52710704d6c9e8c95415`. It rebuilt QMI and SSC from those
exports, staged them into a private prefix, and built the proxy against that
fresh provider stack. Source mounts and the container root were read-only;
network access was disabled and no physical device was exposed. All 123
native commands and six host control commands completed successfully without
timeouts; the container exited normally without an out-of-memory event.

- All six selected unit binaries passed in both ordinary and sanitized
  builds: 286 cases passed and the same unavailable French-locale case was
  skipped in each build.
- All 57 ordinary Python selections and 22 sanitized SSC Claim selections
  passed without skips.
- Executed sanitizer commands included 83 compilations and nine links using
  ASan/UBSan and explicit float-cast-overflow checks. Provider/system libraries
  remained unsanitized.
- The fresh provider libraries and normal CLI were AArch64, had no installed
  RPATH/RUNPATH, and passed loader/help/version checks. The proxy's installation
  plan was inspected and staged under a private `DESTDIR`, with no activation
  or system installation. This is not finished packaging qualification.
- The six known Meson setup advisories and four missing-XMLLINT notices were
  retained. No C compiler diagnostics or sanitizer-error matches were found
  in the inspected compile/test logs; this is not a warning-free blanket claim.

The inherited Python harness also emitted 30 unclosed-polkit-file
`ResourceWarning` messages and two subprocess-still-running warnings during
the ordinary unrequested-reading/legacy Claim tests. These are retained test
harness limitations, not waived hardware failures or a clean resource-shutdown
claim. The bounded container reached its verified terminal state; production
service lifecycle qualification is still open.

The job rechecked source inventories before and after execution. It used the
broader ordinary/sanitized fixture matrix, `/usr` as the proxy's logical prefix
and a private `DESTDIR`; the shorter private-prefix example in BUILDING.md was
syntax-checked, not literally replayed in full. Neither the two public SDK
consumers nor the inverse controls were rerun in this job; their earlier
evidence remains separately scoped above. Command streams and terminal
receipts were retained privately rather than embedding host paths in this
publication; temporary ordinary daemon logs retain the limitation noted above.

## Candidate admission and activation follow-up — 2026-10-20

This source update replaces first-discovered reservations with an owned,
ordered candidate registry. A rejected constructor can fall through to another
driver/source; occupied-type alternatives remain eligible after removal. It
checks the current source revision after discovery and construction, and
observes device events before startup enumeration. Stream starts are prepared
as owned attempt tokens during admission and activated only after that phase
ends. Removal, last-client release and shutdown can invalidate those tokens
without accidentally activating or clearing a replacement.

A fresh isolated native ARM64 run rebuilt the same pinned QMI/SSC providers
and this exact proxy source, using the same no-network/read-only boundaries.
All 141 native commands and six host control commands completed successfully;
all 294 recorded command streams were rehashed against their receipts.

- Seven unit targets passed in both ordinary and sanitized builds: 304 passed
  cases and one known unavailable French-locale skip in each build. This
  includes 18 tests that compile the actual proxy translation unit against
  controlled driver effects and a real private D-Bus daemon.
- All 65 ordinary and 30 selected sanitized Python integration cases passed,
  with no skips. Eight new actual-daemon cases cover constructor fallback,
  events during discovery, removal/shutdown during construction, retaining a
  successful owner and future-intent auto-start replacement.
- The auto-start regression requires a replacement to become available and
  serve a real fixture reading before the stale native OPEN gate is released.
  The 18 selection cases also check cancellation before activation without
  either OPEN or STOP. The production adapter executes; native sensor effects
  are deliberately substituted, not hardware calls.
- Executed sanitizer commands included 87 compilations and ten links using
  ASan/UBSan and explicit float-cast-overflow. Provider/system libraries remained
  unsanitized. The six known Meson advisories, four missing-XMLLINT notices and
  inherited 30 file-resource/two subprocess warnings remain disclosed; this
  is not a warning-free or complete harness-resource-cleanup claim.
- A separate optimized fixture build passed all 18 selection cases and five
  selected positive cases. Five production-only inverse controls then each
  failed by SIGABRT at its exact intended assertion: stopping after a rejected
  constructor, accepting a retired snapshot, omitting the shutdown fence,
  losing the in-flight attempt-wave marker and stopping an unstarted token.
  Test bytes and modes were unchanged in every variant. All 84 recorded
  streams were rehashed; build failures, unrelated assertions and timeouts
  were not accepted as successful inverse controls.

The source and its unchanged provider inventories were rechecked after the
run. The original short-recipe limitation above still applies: this broader
matrix used `/usr` plus a private `DESTDIR`, not a literal replay of every
BUILDING.md command. The added shell example was syntax-checked. Public SDK
consumers and physical providers were not rerun as part of this update.

Only SSC startup-failure hooks receive the bounded first-valid-reading deadline.
Legacy drivers still wait for a valid reading or client release/removal; this
change does not add a universal timeout or authorize success without a reading.
Faulted SSC providers retain manual CLOSE/Claim recovery. Constructor cancellation,
arbitrary device path moves and all external event storms remain unqualified.
Shutdown fences later publication but is not proof of remote firmware quiescence.

## Normal Lexr producer — 2026-10-22

The normal experimental CLI producer at Lexr
[`73aafd72beb05c89e18e0b1e1fccb9874ef1d9d9`](https://github.com/ooaklee/lexr.sh/commit/73aafd72beb05c89e18e0b1e1fccb9874ef1d9d9)
authenticated and built OE `649cc875d08c04ce33bc8afc2a0ff7a22ce362e0`.
Dependency preparation, volume initialisation and offline source compilation
each reached a verified terminal exit of zero. Seven native software fixture
targets passed. Strict validation accepted 16 regular artefact files and three
library aliases, followed by durable local publication and its receipt. An
independent replay of the retained archive passed the unchanged strict consumer.
The [dated Lexr qualification record](https://github.com/ooaklee/lexr.sh/blob/v0.6.0-rc.1/docs/adr/adr-045-local-sensor-build-transport-and-bind-namespaces.md#2026-10-22-local-producer-evidence)
records the software-only boundary.

The producer implementation is unchanged in published Lexr `0.6.0-rc.1`, source
commit [`157e5d3e81c0d0c0c63437a7c549789d021c1bdb`](https://github.com/ooaklee/lexr.sh/commit/157e5d3e81c0d0c0c63437a7c549789d021c1bdb).
No fresh RC native run was performed. This latest run used `b_sanitize=none`
and retained known diagnostics; earlier sanitized evidence remains separately
scoped above.

This completes the software producer/local-publication gate. It does not
establish literal replay of BUILDING.md, installation, service activation,
runtime-provider coexistence, rollback, physical sensor roles, axes, calibration,
clocks, desktop behaviour or suspend/resume qualification.

## Remaining work

- Define reviewed service/package conflict and privilege boundaries, including
  distribution proxy coexistence, rollback and explicit activation.
- Keep catalogue entries experimental and build-only, with installation
  disabled until its separate gates pass. Metadata alone cannot grant
  execution or hardware compatibility.
- Qualify sensor identity, physical roles, axes/mounting, calibration and
  clocks on declared hardware. Then test desktop behavior and suspend/resume.
- Establish explicit kernel/OS compatibility from that qualification, not by
  extrapolating a kernel generation suffix.

The accepted v26/v27 kernels and the Surface remain outside this source
publication. No GLINK transport lifecycle repair is included or claimed.
