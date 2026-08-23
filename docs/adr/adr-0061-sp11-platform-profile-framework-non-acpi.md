---
id: adr-0061-sp11-platform-profile-framework-non-acpi
title: "ADR0061: SP11 Platform Profile Framework on Non-ACPI Systems"
# prettier-ignore
description: Architecture Decision Record (ADR) documenting why power-profiles-daemon showed only the placeholder driver on the Surface Pro 11 and the kernel fix that enables the platform_profile framework on DT-only (ACPI-disabled) systems.
---

# ADR0061: SP11 Platform Profile Framework on Non-ACPI Systems

## Status

Accepted (2026-08-23). Root cause verified on hardware; kernel fix committed
as `05d634c6687e` on branch `sp11/integration-7.2.x-power-profiles` of
`ooaklee/linux_ms_dev_kit-sp11`. Awaiting rebuild on the Mac build host and
hardware re-verification.

## Context

- The Surface Pro 11 (X1E80100) boots with device tree only. ACPI is compiled
  in (`CONFIG_ACPI=y`) but disabled at runtime (`acpi_disabled=1`; boot log
  `ACPI: Interpreter disabled.`); `/sys/firmware/acpi` does not exist.
- power-profiles-daemon 0.30 hardcodes the legacy sysfs path
  `/sys/firmware/acpi/platform_profile` (verified via `strings` on the ppd
  binary; it does not use the newer `/sys/class/platform_profile` class
  interface).
- The generic kernel framework `drivers/acpi/platform_profile.c` (module
  `platform_profile`, `CONFIG_ACPI_PLATFORM_PROFILE=m`) guarded its init with
  `if (acpi_disabled) return -EOPNOTSUPP;`. On the SP11 this made the framework
  module refuse to load.
- `surface_platform_profile` (SP11 SSAM driver for device `01:03:01:00:01`,
  which the `surface_aggregator_registry` creates with `has_fan` and
  `default-low-power` properties) depends on the framework, so it could not
  autoload either (udev modalias `ssam:d01c03t01i00f01` existed but the
  dependency failed).
- Result: no platform profiles anywhere; ppd fell back to its placeholder
  driver and the KDE power profiles UI showed no profiles.

## Decision

- Modify `drivers/acpi/platform_profile.c` so the legacy interface is
  available on non-ACPI systems:
  - Use a module-local `platform_profile_kobj` instead of the exported global
    `acpi_kobj`.
  - In `platform_profile_init()`: if `acpi_kobj` is set, reuse it; otherwise
    create the `acpi` kobject under `firmware_kobj`
    (`kobject_create_and_add("acpi", firmware_kobj)`), which yields exactly
    `/sys/firmware/acpi/platform_profile` and
    `/sys/firmware/acpi/platform_profile_choices` once a class device is
    registered.
  - Track whether the module created the kobject
    (`platform_profile_kobj_created`) so `platform_profile_exit()` only
    `kobject_put()`s when it owns it.
  - Update all `sysfs_notify`/`sysfs_update_group`/`sysfs_create_group`/
    `sysfs_remove_group` call sites to use the local kobject.
- No change to the legacy sysfs path itself: ppd 0.30 keeps working unchanged.
- No change to `surface_platform_profile`; the driver probe path was audited
  and needs nothing ACPI-specific (freq QoS over SCMI cpufreq policies, SSAM
  EC requests, and the registry-created device all work without ACPI).

## Consequences

- On ACPI systems behavior is unchanged (`acpi_kobj` reused, no new kobject
  created).
- On DT-only systems the `platform_profile` framework now loads,
  `surface_platform_profile` can autoload via the existing SSAM modalias, and
  ppd should show balanced/performance etc.
- The fix is a kernel change, so it ships with the next SP11 kernel build from
  `sp11/integration-7.2.x-power-profiles`.
- The ADR is superseded only if ppd or the kernel later adopt a class-based
  interface and the legacy path is dropped.
