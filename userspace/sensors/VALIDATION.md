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

## Fresh exported-source check — 2026-10-20

A new isolated native ARM64 job rebuilt QMI and SSC from these exported
sources, staged them into a private prefix, and built the proxy against that
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

## Remaining work

- Repair and separately test candidate admission/reselection: a failed first
  discovered device can still leave a valid alternate unused.
- Define reviewed service/package conflict and privilege boundaries, including
  distribution proxy coexistence, rollback and explicit activation.
- Add a typed Lexr sensor adapter and catalogue capability before advertising
  Lexr build/install support. Metadata alone cannot grant execution.
- Qualify sensor identity, physical roles, axes/mounting, calibration and
  clocks on declared hardware. Then test desktop behavior and suspend/resume.
- Establish explicit kernel/OS compatibility from that qualification, not by
  extrapolating a kernel generation suffix.

The accepted v26/v27 kernels and the Surface remain outside this source
publication. No GLINK transport lifecycle repair is included or claimed.
