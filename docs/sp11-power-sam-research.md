---
id: sp11-power-sam-research
title: "Surface Pro 11 s2idle, CPUIdle, and SAM Platform-Profile Research"
# prettier-ignore
description: Read-only Wave 1 source findings and mutation gates for the Surface Pro 11 P6 and P7 tracks.
---

# Surface Pro 11 s2idle, CPUIdle, and SAM Platform-Profile Research

## Status and decision boundary

This is a public-source, read-only Wave 1 desk review for P6 and P7. It does
not qualify suspend, identify a failing idle state, prove that the target
firmware implements a performance-profile command, or authorize a firmware,
sysfs, tracefs, service, module, boot, or kernel change.

Read it with the
[execution plan](sp11-full-feature-parity-execution-plan.md), the
[source ledger](sp11-feature-parity-source-ledger.md), and the sanitized
[Wave 1 target report](sp11-wave1-read-only-target-evidence-20260807.md).
The target report is the authority for live observations. The source review
below classifies the live `f02` SSAM node more precisely: the pinned kernel
registry defines it as the thermal-sensor client, not a performance-profile
candidate.

The immediate decisions are:

- keep P6.2 blocked until the P0 recovery gate exits;
- do not create an idle-state patch yet: the pinned baseline already removes
  `cluster_cl5` from the selectable cluster power domains;
- treat the live SSAM `f01`/`f02` mismatch as a hard identity and protocol
  gate;
- do not alias the platform-profile driver to `f02`, probe adjacent functions,
  load a candidate module, or send a raw SSAM request; and
- do not import the demonstration's frequency ceiling or profile count.

## Immutable sources and licences

Only public primary sources were used. Source statements remain distinct from
target observations.

| Source | Immutable identity | Licence and permitted use | Boundary |
|---|---|---|---|
| [JG kernel baseline](https://github.com/jglathe/linux_ms_dev_kit/tree/8f953dd060bc6e8fb86ca2ea8a92f258141c0169) | `8f953dd060bc6e8fb86ca2ea8a92f258141c0169` | Mixed licence; `hamoa.dtsi` and the Denali DTSI are `BSD-3-Clause`; the Surface profile driver and registry are `GPL-2.0+`; review every changed file | Canonical source candidate, not proof of the loaded DT or target firmware behaviour |
| [Hamoa cluster-idle change](https://github.com/jglathe/linux_ms_dev_kit/commit/fb2108597f0055790ced9d6921af50e529f5b35b) | `fb2108597f0055790ced9d6921af50e529f5b35b`, an ancestor of the baseline | `hamoa.dtsi`, `BSD-3-Clause`; source rationale and patch history | Its broad X1 reset rationale is not an SP11 failure reproduction |
| [Initial upstream Surface platform-profile driver](https://github.com/torvalds/linux/commit/b78b4982d7637ededbc40b5f4aa59394acee8a60) | `b78b4982d7637ededbc40b5f4aa59394acee8a60` | `GPL-2.0+`; typed SSAM protocol and driver basis | Supports its exact `f01` match; it does not establish SP11 support |
| [Surface profile fan extension](https://github.com/torvalds/linux/commit/3427c443a6dc2f6171616c2381d037d004af1df0) | `3427c443a6dc2f6171616c2381d037d004af1df0` | `GPL-2.0+`; architecture reference only | No SP11 fan endpoint or safe fan transition is established |
| [SP11 registry addition](https://github.com/jglathe/linux_ms_dev_kit/commit/c4a069095395ecd1e936f488511dfd9016b9c479) | `c4a069095395ecd1e936f488511dfd9016b9c479`, an ancestor of the baseline | `GPL-2.0+`; exact Denali registry evidence | The SP11 group includes `f02` sensors and deliberately does not instantiate `f01` profile support |
| [Surface Aggregator Module repository](https://github.com/linux-surface/surface-aggregator-module/tree/de6d403852f33f5445c25971a3f25e6ebafbf824) | `de6d403852f33f5445c25971a3f25e6ebafbf824` | Top-level GNU GPL v2; relevant module file is `GPL-2.0+`; architecture/protocol corroboration | Predates SP11 support; its raw userspace request tool is not a discovery mechanism |
| [Experimental SSAM command database](https://github.com/linux-surface/surface-aggregator-cmddb/tree/226a69997f89263f903da36517bca639f044382b) | `226a69997f89263f903da36517bca639f044382b` | No repository licence or file SPDX found; evidence only | Do not copy code, YAML, constants, or descriptions into an implementation |
| [Public SP11 ACPI dump](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/ssdt.dsl#L500-L630) | `1d0a2ce742b450fe3f65287adbe174ddccabe228` | No repository licence declared; namespace evidence only | `MSHW0084`/SSH and its dependencies do not prove a TMP function, command, UART-to-DT mapping, or resource value |

The baseline's PM documentation and bindings are also controlling references:
the [sleep-state ABI](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/Documentation/admin-guide/pm/sleep-states.rst)
and [CPUIdle ABI](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/Documentation/admin-guide/pm/cpuidle.rst)
are `GPL-2.0`; the
[CPU idle-state binding](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/Documentation/devicetree/bindings/cpu/idle-states.yaml)
is `GPL-2.0-only OR BSD-2-Clause`; and the
[Surface SAM binding](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/Documentation/devicetree/bindings/embedded-controller/microsoft%2Csurface-sam.yaml)
is `GPL-2.0-only OR BSD-2-Clause`.

## P6 findings

| Classification | Finding | Consequence |
|---|---|---|
| Observed on target | `/sys/power/mem_sleep` reported `s2idle [deep]`; no suspend was initiated | `deep`, not `s2idle`, was selected at observation time |
| Observed on target | PSCI 1.1 with OSI, `psci_idle`/`menu`, WFI at latency/residency 1/1, and `cpu-sleep-0` described as `ret` at 500/600; both states enabled | Useful passive baseline only; no state has been blamed |
| Observed on target | Suspend statistics were zero successes and zero failures | There is no fallback suspend outcome to compare |
| Observed in source | Baseline Hamoa defines leaf `cluster_c4`/`cpu-sleep-0`: description `ret`, PSCI parameter `0x00000004`, entry 180 us, exit 320 us, minimum residency 600 us | The 500 us live latency is consistent with the source entry-plus-exit latency |
| Observed in source | Hamoa defines cluster `cl4` and `cl5`, but commit `fb210859...` leaves only `cl4` referenced by all three cluster power domains | `cl5` is not selectable through those baseline domain references; do not create a redundant removal patch |
| Observed in source | Architectural WFI is implicit and is not described as a DT idle-state node | Retaining WFI is the baseline, not a feature claim |
| Inferred | The live `cpu-sleep-0` probably corresponds to the baseline leaf `cluster_c4` because name, description, latency, and residency agree | Confirm the active DT and power-domain topology before treating that mapping as canonical |
| Unknown | Whether cpuidle, a cluster domain, a dependent device, firmware, a wake source, or userspace causes a resume failure | P6.3 has no defensible candidate yet |
| Unknown | Fallback s2idle entry, failure phase, last successful PM event, wake IRQ/source, device callback error, resume reliability, and energy | P6.2 and every P6 acceptance count remain unstarted |

The source commit says `cl5` caused a DC ZVA-related reset on X1 systems. That
is a source-author statement, not a reproduced SP11 diagnosis. Likewise, the
demonstration's “deeper Denali” wording is not enough to equate its state with
the live leaf state, `cl4`, or the already-detached `cl5` state.

## P6 bounded no-write fallback baseline

This R0 protocol is a 60-second baseline and trace-readiness check. Run it only
when the intended fallback ABI is explicit. It does not select `s2idle`, enter
suspend, enable tracing, clear a buffer, or change an idle state. It therefore
cannot satisfy P6.2 or support a resume claim.

First collect static state and suspend counters:

```sh
set -eu
export LC_ALL=C

read_attr() {
  attr_path=$1
  if [ -r "$attr_path" ]; then
    printf '%s=' "$attr_path"
    tr '\n' ' ' < "$attr_path"
    printf '\n'
  else
    printf '%s=<unreadable>\n' "$attr_path"
  fi
}

printf 'kernel='; uname -r
for attr_path in \
  /sys/power/state \
  /sys/power/mem_sleep \
  /sys/devices/system/cpu/cpuidle/current_driver \
  /sys/devices/system/cpu/cpuidle/current_governor_ro \
  /sys/power/pm_wakeup_irq
do
  read_attr "$attr_path"
done

for attr_path in /sys/power/suspend_stats/*; do
  [ -f "$attr_path" ] || continue
  read_attr "$attr_path"
done

for state_path in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*; do
  [ -d "$state_path" ] || continue
  for field in name desc latency residency default_status disable; do
    read_attr "$state_path/$field"
  done
done
```

Then take two counter snapshots separated by 60 seconds of otherwise idle
wall time. The sampling process itself wakes a CPU, so the result is a bounded
observer-affected baseline rather than a power measurement.

```sh
sample_idle_counters() {
  sample_label=$1
  printf 'sample=%s time=' "$sample_label"
  date -u +%Y-%m-%dT%H:%M:%SZ
  for state_path in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*; do
    [ -d "$state_path" ] || continue
    for field in usage time rejected above below; do
      attr_path=$state_path/$field
      [ -r "$attr_path" ] || continue
      printf '%s=' "$attr_path"
      tr '\n' ' ' < "$attr_path"
      printf '\n'
    done
  done
}

sample_idle_counters T0
sleep 60
sample_idle_counters T1
```

Finally, inspect only whether the relevant tracepoints exist and whether some
other actor already enabled them. Do not read `trace_pipe` and do not write an
event `enable` file, `tracing_on`, `current_tracer`, a buffer control, or the
trace buffer.

```sh
trace_root=/sys/kernel/tracing
[ -r "$trace_root/available_events" ] || \
  trace_root=/sys/kernel/debug/tracing

printf 'trace_root=%s\n' "$trace_root"
[ -r "$trace_root/tracing_on" ] && \
  printf 'tracing_on=%s\n' "$(tr -d '\n' < "$trace_root/tracing_on")"

for event_name in \
  cpu_idle psci_domain_idle_enter psci_domain_idle_exit \
  device_pm_callback_start device_pm_callback_end suspend_resume \
  wakeup_source_activate wakeup_source_deactivate power_domain_target
do
  if grep -Fqx "power:$event_name" "$trace_root/available_events"; then
    printf 'event=power:%s available=yes' "$event_name"
    enable_path=$trace_root/events/power/$event_name/enable
    if [ -r "$enable_path" ]; then
      printf ' enabled=%s' "$(tr -d '\n' < "$enable_path")"
    fi
    printf '\n'
  else
    printf 'event=power:%s available=no\n' "$event_name"
  fi
done
```

If readable, `/sys/kernel/debug/wakeup_sources` and the current- and
previous-boot kernel journals may be inspected separately. They are
local-sensitive evidence. Bound the output, pass journal text through
`scripts/collect-sp11-feature-parity-inventory.sh --filter-kernel-log-stdin`,
and manually review it before publication. The public report may retain state
names, scalar counters, PM phases, errno values, and generic device-driver
names; it must omit access details, account and host names, serials, UUIDs,
network identifiers, raw controller bytes, unfiltered command lines, and raw
traces.

## P7 findings

| Classification | Finding | Consequence |
|---|---|---|
| Observed on target | Live SSAM device `01:03:01:00:02` has modalias `ssam:d01c03t01i00f02` and is unbound | It is an identity observation, not proof of profile support |
| Observed on target | Installed `surface_platform_profile` is GPL, matches `ssam:d01c03t01i00f01`, is not loaded, and exposes no platform-profile class device | Nothing currently matches or offers a profile ABI |
| Observed on target | Three SCMI CPU-frequency policies use the `scmi` driver and `performance` governor over 710400–3417600 kHz | Policy topology is known; profile ownership and safe caps are not |
| Observed in source | The pinned registry names `f01` as the performance-profile client and `f02` as the thermal-sensor client; the Denali/SP11 group includes only `f02` | Correct the central report's “performance candidate” label to “thermal-sensor client” |
| Observed in source | The generic driver matches only `f01`; the SP11 registry does not instantiate it or a fan endpoint | Never broaden the alias to make `f02` bind |
| Observed in source | The generic driver advertises four choices without a capability query | It cannot meet P7's target-specific “only implemented modes” gate without further evidence/design |
| Inferred | The three live SCMI policies are consistent with Hamoa's three CPU clusters and DVFS domains | This does not prove that SSAM owns their limits or that all must share a cap |
| Unknown | Whether SP11 implements `f01`, which modes it supports, the meaning of two opaque GET fields, and whether a fan transition is required | Active GET and every write remain blocked |
| Unknown | Firmware-vs-Linux ownership of any low-power ceiling, thermal limits, acknowledgement, failure atomicity, and rollback | Do not adopt the demonstration's reported ceiling or any other unmeasured constant |

### Public protocol definition

The exact baseline driver defines this protocol for its exact `f01` client:

| Operation | Public definition | Validation and failure boundary |
|---|---|---|
| TMP GET | Target category `0x03`, command `0x02`, no request payload; exact 8-byte response: little-endian 32-bit profile plus two opaque little-endian 16-bit fields | Typed wrapper rejects any non-8-byte response with `-EIO`; only profile values 1–4 are accepted by the conversion function |
| TMP SET | Target category `0x03`, command `0x03`, little-endian 32-bit profile payload; no response payload | Transport completion is not firmware acknowledgement; the baseline driver does not read back after SET |
| Profile mapping | 1 balanced/normal, 2 low-power/battery-saver, 3 balanced-performance, 4 performance | The mapping is established for supported Surface models, not for SP11 |
| Retry | At most three total attempts, and only for `-ETIMEDOUT` or `-EREMOTEIO` | A retry policy does not make an unknown endpoint safe |
| Optional FAN SET | Separate target category `0x05`, command `0x0e`, instance 1, one-byte payload, no response | TMP SET occurs first, so a later FAN failure is non-atomic; SP11 fan applicability is unknown |

No licensed, SP11-specific capability query was found. Reading a future
platform-profile `profile` attribute would invoke TMP GET; it is an active
firmware transaction even though it is not a write. By contrast, class-device
existence, `name`, and `choices` are passive once a driver has registered.

### Discovery levels

R0 is limited to passive topology and metadata:

```sh
set -eu
export LC_ALL=C

for device_path in /sys/bus/ssam/devices/*; do
  [ -d "$device_path" ] || continue
  device_name=${device_path##*/}
  case "$device_name" in
    01:03:01:00:*) ;;
    *) continue ;;
  esac
  printf 'ssam_device=%s\n' "$device_name"
  [ -r "$device_path/modalias" ] && \
    printf 'modalias=%s\n' "$(tr -d '\n' < "$device_path/modalias")"
  if [ -L "$device_path/driver" ]; then
    printf 'driver=%s\n' "$(basename "$(readlink "$device_path/driver")")"
  else
    printf 'driver=<unbound>\n'
  fi
done

modinfo -F license surface_platform_profile 2>/dev/null || true
modinfo -F alias surface_platform_profile 2>/dev/null || true

for profile_path in /sys/class/platform-profile/platform-profile-*; do
  [ -d "$profile_path" ] || continue
  printf 'platform_profile=%s\n' "${profile_path##*/}"
  for field in name choices; do
    [ -r "$profile_path/$field" ] || continue
    printf '%s=' "$field"
    tr '\n' ' ' < "$profile_path/$field"
    printf '\n'
  done
done

for policy_path in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$policy_path" ] || continue
  printf 'policy=%s\n' "${policy_path##*/}"
  for field in affected_cpus related_cpus scaling_driver scaling_governor \
    cpuinfo_min_freq cpuinfo_max_freq scaling_min_freq scaling_max_freq
  do
    [ -r "$policy_path/$field" ] || continue
    printf '%s=' "$field"
    tr '\n' ' ' < "$policy_path/$field"
    printf '\n'
  done
done

systemctl show power-profiles-daemon.service \
  --property=LoadState --property=ActiveState --property=UnitFileState \
  --no-pager 2>/dev/null || true
```

This deliberately does not read `profile`, invoke `powerprofilesctl`, start or
stop a service, load a module, open a raw SSAM device, poll unknown sensors, or
write a CPU-frequency limit. The modern baseline ABI is
`/sys/class/platform-profile/platform-profile-X/{name,choices,profile}`;
collector coverage of only legacy `/sys/firmware/acpi/platform_profile*` paths
would miss it.

R1 would be a typed, GET-only experiment, not an R0 command. It requires P0
recovery completion, an independently justified exact SP11 `f01` match, an
approved one-shot ABI, strict response-length/value validation, bounded
timeouts, and before/after logs. W1 begins with TMP SET and includes every
profile, fan, CPU-frequency, service, and sleep-mode transition. It additionally
requires known prior state, post-write GET verification, defined partial-failure
semantics, and a tested fallback. No R1 or W1 command is provided here.

## Stop conditions

Stop without probing further when any of these applies:

- the only live candidate remains `f02`, or an exact SP11 `f01` basis is absent;
- a proposal relies on alias expansion, adjacent command IDs, a raw userspace
  SSAM tool, unlicensed command-database material, or demonstration constants;
- P0 recovery, the selected fallback, physical recovery, or one-shot boot is
  not qualified;
- another actor already configured tracing or a policy daemon may race the
  observation and its ownership cannot be established read-only;
- a GET times out, returns a transport error, has a non-8-byte response,
  reports an unknown value, or changes any observable state;
- fan presence, transition ordering, profile acknowledgement, or rollback is
  ambiguous; or
- a suspend attempt hard-locks, panics, stalls, loses the expected wake path,
  or requires a manual power cycle. Boot the fallback and preserve the
  previous-boot evidence; do not repeat that candidate automatically.

## Upstream destinations

- Route Hamoa/Denali idle-state data to arm64 Qualcomm DT maintainers, PSCI or
  CPUIdle core work to the ARM power-management maintainers, and a device
  suspend fix to its owning subsystem.
- Offer reusable SSAM protocol and Surface driver work to linux-surface and
  the Linux Surface platform maintainers. Use the baseline kernel's
  `scripts/get_maintainer.pl` for the exact changed files.
- Route generic platform-profile ABI changes to its kernel maintainers and
  Power Profiles Daemon behaviour to that userspace project. Keep
  distribution policy/packaging in this repository when it is not generic.
- Keep board matching/data separate from generic protocol changes. Preserve
  per-file SPDX and copyright notices and leave human DCO certification to a
  human contributor.

## Recommended plan and ledger amendments

Do not apply these changes from this desk-review branch; record them in the
authoritative documents during the next planning/ledger review.

Plan amendments:

1. In P6.1, record `fb210859...` as already present in the baseline and require
   active-DT/domain-topology confirmation before proposing a new idle-state
   ABI. Trace availability inspection is R0; enabling or clearing tracefs is a
   gated test mutation.
2. In P6.2, explicitly require `s2idle` to be selected only after P0 and record
   the pre-test `mem_sleep` selection. The current passive sample had `deep`
   selected and ran no cycle.
3. In P7.1, classify `01:03:01:00:02`/`f02` as the thermal-sensor client, not a
   performance candidate. Add the modern `/sys/class/platform-profile` ABI to
   future inventory coverage.
4. In P7.2/P7.3, record that the public typed protocol is `f01`; no
   SP11-specific capability query was found. Prohibit binding the driver to
   `f02`, require exact match provenance, and account for GET being an active
   firmware request.
5. In P7 acceptance/rollback, require target-derived choices, SET readback,
   and explicit non-atomic TMP/FAN failure handling. The generic driver's four
   unconditional choices and no-response SET are not sufficient by themselves.

Recommended ledger rows or refinements:

| Source | Identity | Recommended ledger treatment |
|---|---|---|
| Hamoa `cl5` detach | `fb2108597f0055790ced9d6921af50e529f5b35b` | Add as `BSD-3-Clause` baseline ancestry and P6 source rationale; not SP11 runtime causality; upstream acceptance still to be verified |
| Surface platform-profile protocol | `b78b4982d7637ededbc40b5f4aa59394acee8a60`, evaluated in baseline `8f953dd...` | Add as `GPL-2.0+` typed protocol/driver basis; exact `f01` only; fixed four choices and SET-without-response are boundaries |
| SP11 Surface registry | `c4a069095395ecd1e936f488511dfd9016b9c479` | Add as `GPL-2.0+` match/topology evidence; Denali group includes sensor `f02` and excludes profile `f01` |
| Surface Aggregator Module | `de6d403852f33f5445c25971a3f25e6ebafbf824` | Refine the existing row: top-level GNU GPL v2, relevant module `GPL-2.0+`, pre-SP11 architecture only; raw-request tooling prohibited |
| Experimental command database | `226a69997f89263f903da36517bca639f044382b` | Add as unlicensed evidence only; no copying or implementation dependency |
| SP11 ACPI dump | `1d0a2ce742b450fe3f65287adbe174ddccabe228` | Refine the existing row: SSH namespace evidence only; no TMP function, Linux match, command, or resource constants inferred |

This Wave 1 desk task exits with research evidence and gates only. P6.1 and
P7.1 may advance to evidence review; P6.2, active profile discovery, and every
write path remain blocked.
