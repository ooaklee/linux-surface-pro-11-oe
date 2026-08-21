# Surface G6 userspace pen processor

`g6-pen` consumes the kernel's versioned `/dev/g6ts-heat` stream, assembles
complete G6 HEAT cycles, tracks generation/reset boundaries, and exposes a
typed virtual pen with uinput.  It also replays the identical record ABI (or a
reviewable text representation) without hardware.

The production configuration is deliberately fail-closed.  The available
Windows captures prove that Windows synthesizes pen input from HEAT and locate
the nested `0xFF00` / kind-`0x5c` signal records, but do not yet prove a
presence discriminator or the proprietary `PenPosition_FindPosition`
reconstruction.  Consequently `hover.enabled=false` is shipped, and the
daemon emits no proximity/contact state until a reviewed field map is
installed.  Tip, pressure, barrel/secondary buttons, eraser, and tilt have no
configuration escape hatch: their validity bits remain clear and uinput keeps
them released/zero.

## Stream ABI

Each `read(2)` from the exclusive-reader misc device returns one complete
record.  A short destination buffer fails with `EMSGSIZE` without dequeuing;
blocking, `O_NONBLOCK`, and `poll(POLLIN|POLLRDNORM)` have normal character
device semantics.  All multibyte fields are little-endian.

| Offset | Type | Field |
| ---: | --- | --- |
| 0 | `le32` | magic `0x31483647` (`G6H1`) |
| 4 | `le16` | ABI version `1` |
| 6 | `le16` | header length `32` |
| 8 | `le32` | total record length |
| 12 | `le32` | transport generation |
| 16 | `le64` | `CLOCK_MONOTONIC` timestamp, ns |
| 24 | `le32` | device-wide enqueue sequence |
| 28 | `le16` | content length, at most `4349` |
| 30 | `u8` | report ID (not repeated in content) |
| 31 | `u8` | flags: bit 0 reset, bit 1 suspend, bit 2 transport fault |
| 32 | bytes | exact HID-SPI content bytes |

The maximum read is 4381 bytes.  Reset, suspend, and transport-fault records
have no content and force an immediate pen-up.  The generation changes before
the kernel flushes the queue and enqueues the boundary.  At live open the
daemon requires `GET_INFO` to confirm version, header/content sizes, queue
capacity, and all three boundary flags before it creates uinput.
`G6_HEAT_IOC_GET_INFO` is
`_IOR('G', 0x00, 48-byte-info)` and `G6_HEAT_IOC_GET_STATS` is
`_IOR('G', 0x01, 112-byte-stats)`; their layouts are mirrored in
`include/g6_heat_abi.h`.  Streaming does not depend on either ioctl.

## Cycle and tracking model

A cycle is anchored by `0c` and then collects the multiset
`0c,0b,1a,0d,0b`.  The assembler accepts all six observed post-anchor orderings
while preserving the first/second `0b` distinction.  Startup traffic before an
anchor is ignored; a new `0c`, duplicate, sequence gap, or a window longer than
30 ms closes an incomplete bundle.  Sequence continuity uses uint32 wrap
semantics.  Any same- or new-generation gap immediately lifts, discards partial
assembly, and requires a clear frame.  The kernel also exports reports `07` and
`6e`; they remain ordered, opaque sideband and can neither complete a cycle nor
open tracking.  In particular, an all-zero `0x6e` identity is normal and is not
a pen-input blocker.

Normal decoded state moves `closed -> acquiring -> hover`.  Valid negative
frames close tracking before a later firmware reset.  A generation change,
reset, suspend, or 50 ms stale watchdog forces pen-up and enters `wait-clear`.
Positive-looking reset traffic cannot reopen the pen: one validated negative
cycle must arrive before acquisition can begin again.

After the first point, each 66.4 Hz core position interval is emitted as four
timestamped linear samples.  In live mode, a monotonic-clock pacer submits them
as distinct uinput `SYN_REPORT`s at 3.75 ms intervals (approximately 266 Hz),
without relying on the ignored userspace `input_event.time`.  A lift or stream
boundary cancels pending samples and is submitted immediately.  Replay is
unpaced and uses only record timestamps, so its JSON output is byte-for-byte
deterministic.

## Current field-map status

Phase-1 analysis found nested metadata records with tag `0xFF00`, kind `0x5c`.
In report `0c`, the section begins at content offset `0x009`; nested records
begin at `0x010` and use `u8 kind, u8 flags, le16 payload_len, payload`.  The
normal region-1 `0x5c` record starts at `0x3ac`.  Its payload is a 12-byte
header followed by two banks of `N` 48-byte vectors.  In all 3,721 audited
P1/P4-P8 records, flags were zero, `N=8`, and payload length was exactly 780;
the decoder requires those v1 invariants.  Header byte `+8` varied among the
observed values 1, 3, and 4 and is deliberately treated as opaque state rather
than a structural discriminator.  Each vector has a
float32 key/frequency at `+0`, a uint32 magnitude candidate at `+4`, eighteen
signed little-endian DFT samples at `+8..+43`, and the four-byte window tuple at
`+44..+47`.  The first bank represents the 68-column axis and the second the
46-row axis.  Sensor-grid output scales to the observed OS space as
`X_h = 405.80996*x - 0.1382` and `Y_h = 401.18737*y - 0.2015`.  This comes from
the simultaneous P4 corpus.  Across 870 outputs, the selected integer center
was within about 0.54 sensor cell of the floating `FindPosition` result; after
coarse scaling that can be roughly 219 X or 217 Y HIMETRIC units.  Separately,
regressing the floating result to HIMETRIC with the formulas above had at most
about 0.54 HIMETRIC residual.  The `ff00-0c-max-energy` decoder implements this
bounded parser, selects the highest-energy valid-trailer vector in each bank,
and applies the regression to the integer center, so it is deliberately a
coarse path.  It still requires explicit energy/presence thresholds; those are
not validated, so the packaged gate remains off.  The 18 DFT samples needed for
subcell position are retained but not guessed at.

The combined P4/P5 presence audit is explicitly negative.  All 1,313 aligned
raw `0c` cycles had nearest processor presence=true, so there is no raw-cycle
negative training class.  Using final in-range as a proxy (1,019 true, 294
false), all 18 tested energy/trailer features overlapped: even the best simple
trailer rule produced 60 false positives and 4 false negatives, while a tested
energy rule produced 92/19.  A false cycle reached total energy 204409 versus a
true minimum of 3930.  No threshold from these captures is safe to ship.

The uinput device uses the synthesized processor contract: X/Y maxima
`27388/18258` at 100 units/mm.  It advertises signed centered tilt
(`-9000..9000`) at 5730 units/radian.  Pressure is `0..4096` with resolution
zero because the descriptor has no physical/unit metadata.  These capabilities
are distinct from the guarded native fallback's `9600/7200` coordinate range;
pressure and tilt events remain gated until their HEAT mappings validate.

P5 confirmed the Windows pressure contract (hover/lift always zero; 1,239
contact reports ranged 518..3745), but no stable raw-HEAT pressure formula.
P6 confirmed signed Cartesian tilt and the Windows transform
`TX=atan(tan(Tilt)*cos(Azimuth))`,
`TY=-atan(tan(Tilt)*sin(Azimuth))` to within one centidegree across 2,397
pairs.  Raw HEAT tilt extraction is still unresolved, so these findings define
types/ranges only and do not relax any emission gate.

The P7 barrel-button capture did not observe the intended action: all 1,908
relevant digital-processor events and all 2,530 pen reports kept both button
states clear.  It therefore supplies no raw barrel or secondary-button map;
both remain hard-gated.

P8 validates the final typed eraser contract: eraser hover carries in-range and
invert with zero pressure, while eraser contact adds the eraser switch and
pressure.  It does not identify the upstream HEAT tool fields, so the daemon
does not synthesize eraser state and the tool gate remains hard-closed.

The optional `rect-centroid` decoder exists to exercise the complete
pipeline with synthetic or newly validated maps.  Its keys are demonstrated
in `tests/corpus/synthetic-hover.conf`: source report/instance, byte offset,
rows/columns/strides, `u8`, `s8`, `u16le`, or `s16le` samples, baseline,
polarity, cell/peak/energy thresholds, inversion, and output range.  It must
not be presented as the production decoder for the nested DFT vectors.  A
future reviewed configuration for the evidence-backed coarse path must use
`map.decoder=ff00-0c-max-energy`, report `0x0c`, instance `0`, and validated
`map.min_peak`/`map.min_energy` presence thresholds.

## Build and deterministic replay

```sh
make
make check
./g6-pen --config tests/corpus/synthetic-hover.conf \
  --replay-text tests/corpus/synthetic-hover.g6t --emit-json
```

`make check` runs ABI, six-order bundle, bounded FF00 coarse decoding,
anchor/re-anchor, sequence-gap/wrap, interpolation, tracking-close,
generation-inhibit, stale-lift, text-replay, and binary-replay tests.  Replays
never create uinput devices.

Convert a sanitized Windows `hidspi-rx-bodies.csv`, then optionally pack it as
the exact binary device stream:

```sh
python3 tools/g6-corpus.py windows-csv hidspi-rx-bodies.csv capture.g6t
python3 tools/g6-corpus.py pack capture.g6t capture.g6h
./g6-pen --config /path/to/validated.conf --replay capture.g6h --emit-json
```

Pass `--include-sideband` only for private diagnostics.  Report `0x6e` may
contain a device or pen identifier; the converter warns and marks the output,
which must be sanitized before sharing.

For live diagnostics without input injection, use `--no-uinput --emit-json`.
