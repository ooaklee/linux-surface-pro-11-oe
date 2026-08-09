---
id: sp11-g6-hidraw-iptsd-research
title: "Surface Pro 11 G6 HIDRAW and IPTSD Research"
# prettier-ignore
description: Provenance-safe transport, HIDRAW, report-schema, pen, and IPTSD execution gates for the Surface Pro 11 G6 touchscreen.
---

# Surface Pro 11 G6 HIDRAW and IPTSD Research

## Result

Preserve the working custom QSPI/GPI transport and add a HIDRAW-only HID child
before attempting pen parsing. Do not point stock IPTSD at the G6 device.

The first kernel change must expose independently observed reports without
changing the controller mode or creating a second touch input device. A later
evidence gate decides whether the pen is standard HID, requires an IPTSD G6
backend, or needs a separate independently developed parser.

This is a research and execution boundary, not evidence that pen works. No
target state was changed to reach this decision.

## Pinned evidence

### Current G6 transport

The released touchscreen modules are built from geocausa commit
[`6bbcf7a4759a73014047a57e819219dd7f34951a`](https://github.com/geocausa/SP11X1e-touchscreen/tree/6bbcf7a4759a73014047a57e819219dd7f34951a).
At that revision, the client:

- requires a 1,484-byte report descriptor and validates device identity
  `045e:0c83`, version `0004` during enumeration;
- requests the report descriptor but neither retains nor hashes it;
- creates no Linux HID device or HIDRAW node;
- handles spontaneous DATA report IDs `0x40` and `0x12`, while other IDs are
  not surfaced to userspace; and
- registers a separate `BUS_SPI`, ten-slot, finger-only multitouch input
  device.

The Phase 91 release wrapper packages the client from the repository's
`phase55/modules` build directory; neither label is a runtime profile. The
installed module receives no client profile parameters, so its compiled
defaults select the Phase 75 runtime profile. The controller-only
`sp11_windows_se_init` option does not change that client selection. The
collector therefore records `behavior_stats`'s `profile` value instead of
inferring runtime behavior from a repository or release name.

The sanitized
[Wave 1 read-only target report](sp11-wave1-read-only-target-evidence-20260807.md)
confirms that distinction and the present ownership boundary: the G6 SPI
client exposes the existing touch-oriented `BUS_SPI` input device directly,
with no G6 HID child, G6 HIDRAW node, or IPTSD installation. That observation
partially satisfies P2.1; descriptor retention and report diagnostics remain
absent.

The device descriptor, report descriptor, synchronous replies, and
spontaneous DATA pass through a shared response buffer in the current client.
The bridge must therefore copy the validated report descriptor into owned
storage before a later transaction overwrites it. Classification remains at
the response-ingress boundary: only the spontaneous DATA class may reach HID
core, even when a synchronous feature exchange encounters and skips DATA
while waiting for its own reply.

The public source's descriptor analysis describes Pen report ID `0x01`, but
that is a candidate to verify from Linux, not proof that the target emits a
complete pen report. The first hardware gate records only the live descriptor
hash and report ID/size histograms; it does not publish personal strokes or raw
payloads.

### Exact JG HID baseline

The kernel contract was reviewed at the exact JG baseline,
[`8f953dd060bc6e8fb86ca2ea8a92f258141c0169`](https://github.com/jglathe/linux_ms_dev_kit/tree/8f953dd060bc6e8fb86ca2ea8a92f258141c0169).
At that revision, a transport must provide a synchronous `raw_request`
callback before `hid_add_device()` will accept its child. HID core calls the
transport's descriptor parser during `hid_add_device()` and may use its
callbacks after registration begins; after `hid_destroy_device()` returns, it
will no longer use them. These are the exact baseline's published Linux
[HID transport rules](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/Documentation/hid/hid-transport.rst).

Allowing `hid-generic` to bind is unsafe for the diagnostic bridge because its
default connect mask includes both HID input and HIDRAW. A G6-specific upper
HID driver must therefore bind the child, parse the retained descriptor, start
it with `HID_CONNECT_HIDRAW`, and call `hid_hw_stop()` on removal. Its
low-level `start`, `stop`, `open`, `close`, and power callbacks must not change
transport or controller state. `raw_request` and `output_report` must reject
all operations without touching QSPI; leaving the higher-level request
callback unset routes requests to the same rejecting raw callback.

This baseline supports `BUS_SPI`, but its HID log-name switch and device-ID
helpers do not yet name that bus. Patch 02 of HID-over-SPI v4 adds only those
generic definitions and can be evaluated independently; the child can also
match with the baseline's existing generic HID device-ID helper. Neither
choice supplies a transport.

### IPTSD v3.1.0

The evidence-only userspace research pin is linux-surface IPTSD commit
[`a83bc1232f7096f8b33b50fdbda249cd640de670`](https://github.com/linux-surface/iptsd/tree/a83bc1232f7096f8b33b50fdbda249cd640de670),
tagged v3.1.0 and licensed `GPL-2.0-or-later`.

It is not safe as a discovery tool on this device:

- discovery opens HIDRAW read/write and can request metadata;
- the runner writes a multitouch feature mode on start and a singletouch mode
  on exit;
- no `045e:0c83` geometry preset exists;
- its descriptor predicates and heatmap framing have not been proven against
  a Linux-captured G6 descriptor and reports; and
- the upstream service and generic udev discovery rule do not provide the
  device-specific restriction required for this experiment.

An ID match is insufficient. A G6 backend is considered only if the live
descriptor passes the reviewed usage predicates, the report framing is mapped
from independently captured Linux data, and physical geometry is measured or
obtained through a separately reviewed read-only path.

### Generic HID-over-SPI

Jingyuan Liang's public
[HID-over-SPI v4 series](https://lore.kernel.org/all/20260609-send-upstream-v4-0-b843d5e6ced3%40chromium.org/)
is the preferred long-term upstream architecture. It registers a Linux HID
device, parses the report descriptor, implements control requests, and feeds
spontaneous data into HID core.

The reviewed public thread is based on Linux commit
`05f7e89ab9731565d8a62e3b5d1ec206485eeb0b`; that commit is an ancestor of the
exact JG baseline. The ledgered, decompressed thread has SHA-256
`3b26ce90730b9bb4d1ff8394db65fcf5f999c94329973fa673dca582ff13f0ca`.
All eleven tracked patches apply textually to the exact JG baseline without a
context reject. This proves mechanical applicability only, not a successful
build, protocol correctness, or maintainer acceptance.

It is not a drop-in replacement for the current SP11 transport. The v4 ACPI
and device-tree paths force `hid-over-spi-flags` to zero because multi-SPI is
unsupported. The series uses ordinary SPI transfers and does not select the
quad transmit/receive mode used by the current SP11 client. It also rejects
multi-fragment input reports. Separately, it owns reset, power, IRQ,
descriptor, and control-request lifecycle itself, so it cannot be layered as
a child while the custom client owns the same SPI device. The QSPI/GPI port
must deliberately merge those responsibilities rather than add a competing
binding.

The archived thread also contains unresolved automated-review reports about
bounds, shared response state, and late-response synchronization. Those are
tool findings, not maintainer conclusions, but they require an independent
audit and tests before any code is reused. Patch reuse must preserve original
authorship and per-file SPDX tags; the mbox remains evidence-only until that
review is complete.

## Architecture decision

The first implementation has five ownership boundaries:

1. The current custom driver continues to own reset, enumeration, synchronous
   GET/SET responses, controller mode, GPI/QSPI operation, recovery, and the
   existing finger input device.
2. After a successful enumeration, the client copies and retains the report
   descriptor response only after its response class, ID, and declared length
   are checked, then creates a G6-specific `BUS_SPI` HID child with the device
   descriptor's vendor, product, and version. The G6-specific upper HID driver
   must be registered before `hid_add_device()`, HID core must parse the copied
   descriptor successfully, and that driver must win the binding before the
   child is published; `hid-generic` binding is a test failure.
3. The upper driver connects with `HID_CONNECT_HIDRAW` only. Generic HID input
   and HID multitouch remain disconnected to prevent duplicate touch events.
4. Low-level lifecycle callbacks are local no-ops, while `raw_request` and
   `output_report` return `-EOPNOTSUPP`. They never acquire the transport lock,
   change mode or power, or send QSPI traffic.
5. Spontaneous DATA reports alone are delivered as report ID plus payload.
   Synchronous control replies are never injected as input. Initial raw
   callbacks reject every transport-backed GET, SET, OUTPUT, and unknown
   request. HIDRAW reads receive only admitted spontaneous DATA; its local
   information ioctls may serve retained identity and descriptor data.

The child lifetime follows one copied, HID-core-parsed descriptor generation.
Registration failure destroys the unclaimed child and leaves no published
pointer. Normal ingress and detachment must be serialized so teardown first
blocks new input and drains an in-flight `hid_input_report()` before clearing
the pointer;
`hid_destroy_device()` then runs outside that serialization lock, before the
parent transport's resources are released. Suspend gates report delivery
before IRQ and power quiescence but keeps the child registered. Resume enables
delivery only after transport recovery and descriptor revalidation; any
descriptor drift leaves delivery disabled and forces a controlled child
destroy/recreate decision rather than mutating a registered descriptor.

The HIDRAW node is root-only during research. Collection opens it read-only,
is time-bounded, stores raw material outside git, and publishes only hashes,
counts, lengths, and independently derived field descriptions.

### Smallest pre-P0 synthetic test seam

The first patch is testable without a device and without copying a G6 report
descriptor. A small, invented vendor-page descriptor and synthetic IDs are
sufficient for these tests:

1. Extract a bounded response classifier that receives response class,
   report ID, declared length, and available length. A table test admits only
   well-formed spontaneous DATA, preserves the exact report ID plus payload,
   and drops descriptor/control/reset replies, unknown classes, truncation,
   oversize, zero-length, and off-by-one cases.
2. Register a synthetic child with the G6-specific upper driver. Its retained
   descriptor must parse, `HID_CLAIMED_HIDRAW` must be set,
   `HID_CLAIMED_INPUT` must remain clear, and its HID input list must stay
   empty. A feed spy receives one admitted spontaneous report and no
   synchronous reply.
3. Replace every QSPI/control operation with a fail-on-call counter. Exercise
   GET and SET raw requests, output reports, malformed lengths, open/close,
   start/stop, and power hints. Control and output calls must return the
   documented rejection, all transport counters must remain zero, and input
   buffers must remain unchanged.
4. Exercise parser and registration failures, repeated create/destroy,
   detach during ingress, suspend gating, resume with the same descriptor,
   and resume with descriptor drift. No failure may leave a published child,
   feed after detach, call a freed callback, or change parent mode/power state.

Run this seam in the pinned touchscreen transport fork and compile the
production module against the exact JG arm64 build tree. Run its KUnit or
equivalent exact-tree offline tests plus the existing static checks before P0
permits a one-shot hardware build. Generic kernel helpers, if later required,
receive their own thin-fork branch and tests. Captured report bytes, the real
descriptor, and hardware access are not required for this stage.

Candidate K1a commit
[`1807d22a476360a05a5b4c865f5e8ad857ae5721`](https://github.com/ooaklee/SP11X1e-touchscreen/commit/1807d22a476360a05a5b4c865f5e8ad857ae5721)
implements only that bounded off-target ingress classifier. It passes synthetic,
sanitizer, CI, and retained-v3-header compile checks, but retains no descriptor,
publishes no HID child, logs no payload, issues no hardware command, and has not
run on the target. It is not P2.3 completion.

## Execution branches and gates

| Sequence | Branch | Scope and exit gate |
|---|---|---|
| G6-R0 | `lsp11-x-g6-contract-research` | Ledger, ADR, collector schema, privacy boundary, and no target mutation |
| G6-K1 | `lsp11-x-g6-hidraw-bridge-7.2-rc5` in the public `ooaklee/SP11X1e-touchscreen` fork, based on exact geocausa commit `6bbcf7a4759a73014047a57e819219dd7f34951a` | Retained descriptor, HIDRAW-only child, rejecting controls, scalar counters, and synthetic/KUnit tests; preserve GPL provenance and keep generic kernel deltas separate |
| G6-C1 | `lsp11-x-g6-report-schema` in the support repository | Descriptor-only checker and bounded local histogram tool; publish no report payloads |
| G6-D1 | Decision gate | Select standard HID pen, an IPTSD G6 backend, another independently licensed parser, or stop |
| G6-U1 | `lsp11-x-iptsd-g6-v3.1.0` in a dedicated IPTSD fork | Only if required: read-only transport-owned mode, exact descriptor allowlist, pen-only output, unit/fuzz tests |
| G6-P1 | `lsp11-x-g6-pen-package` in the support repository | Disabled-by-default restricted service, explicit device access, measured geometry, clean uninstall |
| G6-I1 | `lsp11-x-g6-pen-integration-7.2-rc5` in the kernel fork | One-shot device matrix and regression evidence |
| G6-UP1 | `lsp11-x-spi-hid-qspi-7.2-rc5` in the kernel fork | Parallel long-term port of public HID-over-SPI to the validated QSPI lifecycle |

Each kernel branch starts from the protected integration branch. The G6
transport branch instead starts from its exact external-module source commit;
its eventual kernel package still uses a distinct co-installable ABI. No
candidate can become the persistent boot default until the one-shot recovery
contract is proven on the target.

## Collector schema

The public inventory may record:

- module path, SHA-256, source version, vermagic, and an explicit allowlist of
  boolean profile parameters;
- `behavior_stats` profile, initialization stage, mode state, heat/error,
  reset/recovery, IRQ, DMA, and framing counters;
- SPI-to-HID-to-HIDRAW topology, bound drivers, modalias, and `BUS_SPI`
  vendor/product/version;
- report-descriptor length, SHA-256, collection/usage summary, report IDs, and
  bit lengths, but not descriptor bytes by default;
- per-report-ID count and min/max/last size, unknown-ID count, and malformed
  length count; and
- safe evdev capabilities and service hardening state.

It must exclude feature/CFU/provider arrays, raw headers and payloads,
handwriting trajectories, device identifiers unrelated to the G6 contract,
firmware, private traces, and remote-access details. `lsusb` is not G6
identity evidence because the live controller is on SPI.

## Hardware sequence

1. Complete offline compile, static analysis, malformed-length tests,
   synthetic descriptor tests, and control-operation rejection tests.
2. Confirm recovery media, the saved fallback, and a no-op one-shot boot before
   installing the distinct diagnostic ABI.
3. Boot the HIDRAW bridge once. Record the device descriptor, live report
   descriptor SHA-256, and report ID/size histograms across idle, finger, pen
   hover, and pen contact. Do not retain payloads beyond local schema work.
4. Repeat five cold and five warm starts. Any descriptor or framing drift
   blocks parser work.
5. In bounded local sessions, derive fields for out-of-range, hover, contact,
   pressure sweep, every observed physical control, eraser, palm, and
   simultaneous touch. Replace the captures with synthetic fixtures.
6. Run offline parser and fuzz tests. If the standard HID pen collection is
   selected, add a reviewed pen-only collection mapping without substituting
   the descriptor, and prove it cannot create a second touch node or events.
   If IPTSD is selected, enable pen-only output manually for a single one-shot
   boot while kernel touch remains authoritative.
7. Acceptance covers 100 hover cycles, 200 strokes, ten pressure sweeps, 50
   cycles for every evidenced control, palm/touch coexistence, cold boots, and
   s2idle. Service restarts apply only to a userspace parser path; a standard
   kernel-HID path instead repeats bind/boot and duplicate-touch checks. Record
   observed ranges and semantics.

## Rollback and no-go boundary

For a userspace parser path, rollback stops and disables the experimental
service and revokes its device rule. For a standard kernel-HID path, rollback
boots the known-good v3 ABI and removes only the experimental ABI after
evidence capture. Neither path replaces the fallback's initramfs module set.

Stop immediately on duplicate touch devices, an unexpected control write,
descriptor drift, IRQ or reset storm, stuck contact, lost ordinary touch, or
failure to return to the fallback after reset.

The following are out of scope:

- stock IPTSD or generic udev auto-start on the live G6 node;
- any transport-backed raw GET/SET/OUTPUT request, mode change, firmware/CFU
  operation, or replay of unknown reports during discovery;
- firmware flashing, SPI scans, spidev competition, descriptor substitution,
  or vendor/product spoofing;
- generic HID-over-SPI deployment before QSPI and lifecycle parity are proven;
- simultaneous generic HID touch and the existing finger device;
- public raw strokes, handwriting, firmware, private captures, or proprietary
  research material; and
- a combined transport, parser, packaging, and persistent-default migration in
  one trial.

## Upstream destinations

Route the generic HID child and HID-over-SPI work to Linux HID/input
maintainers, generic GENI/GPI changes to their Qualcomm subsystem maintainers,
and Denali device-tree data to arm64 Qualcomm/DT maintainers. Offer an
independently justified G6 backend to IPTSD only if its maintainers accept the
architecture. Keep packaging, service policy, recovery tooling, and target
evidence in this support repository.
