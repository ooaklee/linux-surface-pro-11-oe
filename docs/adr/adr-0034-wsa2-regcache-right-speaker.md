---
id: adr-0034-wsa2-regcache-right-speaker
title: "ADR0034: Right Speaker Silence — SoundWire Port Mapping and Regmap Cache"
# prettier-ignore
description: Architecture Decision Record (ADR) for the right speaker silence on the Surface Pro 11.
---

# ADR0034: Right Speaker Silence — SoundWire Port Mapping and Regmap Cache

## Status

Superseded by [ADR-0036](adr-0036-right-speaker-audio-position-reorder.md) —
The right speaker is now working via a PipeWire `audio.position` reorder that
bypasses the kernel DAPM gate (2026-06-19). The original Track A left-mono
workaround is no longer needed. The DAPM gate root cause remains unresolved at
the kernel level but is fully worked around in userspace.

## Update (2026-06-19)

The right speaker now produces audio. The workaround does not fix the kernel
DAPM gate — the DMA RX_0 bit 1 (right path) still reads `off` and cannot be
forced on via `amixer`. Instead, the fix reorders PipeWire's `audio.position`
labels from `[ FL FR RL RR ]` to `[ FL RL FR RR ]`, which causes PipeWire's
channelmix to route signal to ch2 (the right physical speaker) under the `FR`
label. This bypasses the DAPM gate entirely. See
[ADR-0036](adr-0036-right-speaker-audio-position-reorder.md) for details.

The right speaker's PA Volume was also boosted from the default 12/31 to
31/31 to match the left speaker's volume. See
`scripts/sp11-enable-wsa-routing.sh`.

## Results: Track A (2026-06-15)

| Check | Result |
|---|---|
| Card | Card0 `X1E80100Microso` instantiated with topology |
| WSA macro 6b00000.codec (prefix `WSA`) | Active — drives `soundwire@6b10000`, registers `WSA` controls, DAPM widgets load |
| WSA macro 6aa0000.codec (prefix `WSA2`) | Bound but dead — `soundwire@6ab0000` is `disabled` in DTS |
| SoundWire bus 1 (6b10000) | Active, master sdw-master-1-0 |
| Left WSA884x amp (sdw:1:0:0217:0204:00:0) | Attached, `SpkrLeft` controls respond |
| Right WSA884x amp (sdw:1:0:0217:0204:00:1) | Attached, `SpkrRight` controls respond, no audio |
| DMA RX_0 bit 0 (left path) | Powers on |
| DMA RX_0 bit 1 (right path) | Stuck `off` — unreachable via amixer |
| speaker-test ch0 (Front Left) | Heard from left speaker |
| speaker-test ch1 (Front Left) | Heard from left speaker |
| speaker-test ch2 (Front Right) | Silent |
| speaker-test ch3 (Rear Right) | Silent |
| PipeWire workaround | 4ch sink with left-mono channelmix matrix |

## Context

### Architecture

The Surface Pro 11 has two LPASS WSA digital macros, two SoundWire buses, and
two WSA884x speaker amplifiers on a single active bus:

| Component | DTS node | Prefix | Status | Kernel device |
|---|---|---|---|---|
| WSA macro 1 | `codec@6b00000` | `WSA` | Active | Yes |
| WSA macro 2 | `codec@6aa0000` | `WSA2` | Bound to driver | Yes (idle) |
| SoundWire bus WSA | `soundwire@6b10000` | WSA | `okay` | Yes |
| SoundWire bus WSA2 | `soundwire@6ab0000` | WSA2 | `disabled` | No |
| Left speaker amp | `soundwire@6b10000/speaker@0,0` | — | Attached | sdw:1:0:0217:0204:00:0 |
| Right speaker amp | `soundwire@6b10000/speaker@0,1` | — | Attached | sdw:1:0:0217:0204:00:1 |

Both speaker amplifiers are on the **same** SoundWire bus (`6b10000`), driven by
the **single** active WSA macro (`6b00000`, prefix `WSA`). The second macro
(`6aa0000`, prefix `WSA2`) is probed but has nowhere to go — its SoundWire bus
(`6ab0000`) is `status = "disabled"` in the device tree. It does not register
DAPM widgets with the card.

The 4-channel speaker PCM (`hw:X1E80100Microso,1`, MultiMedia2) routes through
`WSA_CODEC_DMA_RX_0` → WSA macro 6b00000 → SoundWire bus → both WSA884x amps.

### Discovery

On every boot, the kernel reports:

```
wsa_macro 6b00000.codec: using zero-initialized flat cache,
                          this may cause unexpected behavior
```

**This warning is on 6b00000 — the active, working macro.** It is the ONLY
macro driving the SoundWire bus. The `zero-initialized flat cache` message
indicates a `REGCACHE_FLAT` regmap initialized with all-zero values rather than
silicon defaults, but upstream `lpass-wsa-macro.c` does supply an explicit
`reg_defaults` table before `devm_regmap_init_mmio()`. The warning alone does
not prove the cache is broken for all register ranges.

The observed symptoms at the control level:

```
amixer -c0 cget numid=68
# WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2
# : values=on,off

amixer -c0 cset numid=68 'on,on'
# : values=on,off   ← second bit stays off
```

Only `WSA`-prefixed controls exist (36 controls). No `WSA2`-prefixed controls
appear, which is expected because `6aa0000` has no SoundWire bus to drive.

### Investigation

1. **Channel-by-channel sweep (`speaker-test hw:0,1 -c 4`):** ch0 and ch1
   produce audio from the left speaker (woofer + tweeter). ch2 and ch3 are
   silent. See
   [installed-audio-speaker-wsa2-test-20260615.md](../installed-audio-speaker-wsa2-test-20260615.md).

2. **Amplifier control parity:** All `SpkrRight` controls mirror `SpkrLeft` and
   respond to writes. `SpkrRight PA Volume` boosted to 31 with `SpkrLeft PA
    Volume` at 0 produces silence — the right amp appears enabled, and the
    silence is consistent with no audio signal reaching it.

3. **WSA macro 2 is dead-end:** `soundwire@6ab0000` reads `status = "disabled"`
   from DTS. `6aa0000.codec` is bound to the `wsa_macro` driver but has no
   `consumer` links in sysfs — it drives nothing.

4. **ASoC debugfs unavailable:** `/sys/kernel/debug/asoc/` is empty in this
   kernel build — no `components`, `codecs`, or `dapm` entries exposed. This
   prevents direct inspection of which DAPM widgets are in the card graph.

5. **Unbind/rebind of 6b00000 failed:** Unbinding kills the entire sound card.
   Rebinding fails with `-EEXIST: failed to register clk 'mclk'` — a clock
   unregister leak bug. A reboot restored the card.

## Decision

We will deploy a left-mono workaround and treat the right-speaker silence as an
unresolved kernel-level issue with multiple plausible causes.

The workaround wraps the 4-channel PCM (`hw:X1E80100Microso,1`) with a PipeWire
channelmix matrix that sums stereo L+R to ch0+ch1 (left woofer + tweeter):

```
channelmix.mix-matrix  = "[ 0.5 0.5, 0.5 0.5, 0.0 0.0, 0.0 0.0 ]"
```

Each stereo input channel contributes 0.5 to left woofer (ch0) and 0.5 to left
tweeter (ch1). ch2 and ch3 are zeroed because they are silent at the kernel
level. The full stereo signal is preserved in mono on the working left speaker.

The `sp11-pipewire-speaker-sink.sh` script pre-sets all WSA and amplifier
controls. These include right-side controls (`SpkrRight PBR`, `SpkrRight PA
Volume`) as no-ops — they are ready for when the kernel fix lands.

## Hypotheses for Right Speaker Silence

The root cause is not yet proven. Plausible causes, ordered from most to least
likely:

### 1. SoundWire port / channel mapping (strong suspect)

The WSA macro maps PCM channels to SoundWire ports. If the topology or DTS
assigns ch2+ch3 to a SoundWire port that isn't connected to the second WSA884x
amplifier, or if the port routing within the macro is incorrect, those channels
go nowhere. The CRD template topology may define port mappings that don't match
the Denali DTS's `soundwire@6b10000` configuration.

**Investigation needed:**
- Compare `qcom,ports-sinterval`, `qcom,ports-offset1/2`, `qcom,ports-word-length`
  in the active DTS against the topology's port definitions.
- Check SoundWire `dp0_sink` through `dp5_sink` on both WSA884x devices for
  which data port each amplifier listens on.
- Verify the DAI link's `sound-dai` phandles (`0xce` = speaker@0,0,
  `0xcf` = speaker@0,1) resolve to matching topology endpoints.

### 2. Regmap cache partial corruption (possible)

The `zero-initialized flat cache` warning is on 6b00000, the working macro.
Upstream code supplies `reg_defaults`, but the warning indicates a
defaults-vs-cache mismatch occurred. While this does not prevent ch0+ch1 from
working, it may corrupt specific registers controlling the right-channel DAPM
path, the SoundWire port enable, or the second DMA RX bit.

**Investigation needed:**
- Read relevant register ranges via `/sys/kernel/debug/regmap` to compare cached
  vs hardware values for suspected registers.
- Test with a kernel patch that forces `REGCACHE_NONE` or `REGCACHE_RBTREE` with
  a verified defaults table.

### 3. CRD topology only defines one WSA speaker path

The topology was generated from the `X1E80100-CRD.m4` template, which is a
reference design board. It may define only a single WSA speaker endpoint rather
than a stereo pair. The 4-channel PCMs exist in the topology (MultiMedia1-4),
but the backend routing to the second WSA884x amplifier may be absent.

**Investigation needed:**
- Decompile the `.tplg.bin` with `alsatplg -d` and inspect the backend DAI links
  for WSA speaker endpoints.
- Compare against the dwhinham Arch Linux topology (if available) which reports
  working right speaker.

### 4. WSA884x bootstrap / PA enable incomplete

The right WSA884x amp is `Attached` and responds to controls, but it may need a
device-specific enable sequence that the generic `wsa884x` driver doesn't
trigger. The WSA884x has an internal DSP that needs firmware, and the bootstrap
sequence involves register writes that the Linux driver may do differently than
Windows.

**Investigation needed:**
- Compare the WSA884x register init sequence between `wsa884x.c` and any known
  working reference (e.g., Windows register traces or downstream CAF kernel).
- Dump the WSA884x `dev-properties` and `dp*_sink` sysfs entries for both amps.

### 5. Regulator, pinctrl, or reset differences

The two WSA884x amplifiers may be on separate regulator rails or reset lines. If
the second amplifier's supply is not enabled or its reset is held, it would
appear `Attached` on the bus but fail to produce audio.

**Investigation needed:**
- Compare `supplier:regulator:*` entries in sysfs between the two WSA884x devices.
- Check `pinctrl-0` and `reset-names` in the DTS `soundwire@6b10000` node.

### 6. Channel layout assumption is wrong

The assumption that ch0+ch1 = left (woofer+tweeter), ch2+ch3 = right
(woofer+tweeter) comes from ALSA's labels (`Front Left`, `Front Right`, `Rear
Left`, `Rear Right`) but the ALSA channel names are assigned by the topology,
not verified against the physical speaker layout. If ch1 is actually a different
left speaker driver or a floating channel, the channel mapping may differ.

**Investigation needed:**
- Isolate which physical speaker driver produces sound for each of ch0 and ch1
  by covering one speaker at a time during a tone test.

## Kernel Fix Direction

The fix is in `sound/soc/codecs/lpass-wsa-macro.c`. The file
`lpass-macro-common.c` handles shared power-domain and version helpers only, not
the WSA regmap config.

### Regmap investigation

The regmap configuration is set in `lpass-wsa-macro.c`. The static initializer
defines the core parameters, and `.reg_defaults` / `.num_reg_defaults` are
assigned later in the probe function:

```c
static const struct regmap_config wsa_regmap_config = {
    .reg_bits = 16,
    .reg_stride = 4,
    .val_bits = 32,
    .max_register = WSA_MAX_OFFSET,
    .cache_type = REGCACHE_FLAT,
    .writeable_reg = wsa_is_writeable_register,
    .volatile_reg = wsa_is_volatile_register,
    .readable_reg = wsa_is_readable_register,
    /* .reg_defaults and .num_reg_defaults assigned in probe */
};
```

Areas to inspect:
- Is `wsa_defaults[]` complete (covers all registers up to `WSA_MAX_OFFSET`)?
- Does `wsa_is_readable_register()` exclude registers that the hardware reads
  differently from the defaults?
- Does `wsa_is_volatile_register()` correctly mark registers that change
  autonomously (e.g., SoundWire status, DMA RX enable bits)?
- Is `REGCACHE_FLAT` the right type? `REGCACHE_RBTREE` would only store
  registers that have been read, potentially catching uninitialized reads —
  but it would not proactively read hardware defaults. It works with the
  `reg_defaults` table.

### Clock unregister leak

The `-EEXIST: failed to register clk 'mclk'` on rebind is a separate bug in the
clock provider registration/cleanup path of `lpass-wsa-macro.c`. The clock is
not unregistered on driver unbind, causing the second probe to fail.

## Consequences

- Users hear audio from the left speaker only. Full stereo content is summed to
  mono on the working channel.
- The `sp11-pipewire-speaker-sink.sh` script is ready for a kernel fix: changing
  the matrix to `[ 1.0 0.0, 1.0 0.0, 0.0 1.0, 0.0 1.0 ]` restores true stereo
  with no script API changes.
- Dummy Output is eliminated — the sink appears as "Surface Pro 11 Speakers."

## References

- `scripts/sp11-pipewire-speaker-sink.sh` — manual PipeWire sink workaround
- `docs/how-to/how-to-bring-up-audio.md` — audio bring-up guide
- `docs/adr/adr-0033-audio-topology-gap.md` — topology gap (resolved)
- `docs/installed-audio-speaker-wsa2-test-20260615.md` — interactive test log
- `sound/soc/codecs/lpass-wsa-macro.c` — WSA macro driver (regmap, DAPM, SoundWire)
- `sound/soc/codecs/wsa884x.c` — WSA884x speaker amplifier driver
