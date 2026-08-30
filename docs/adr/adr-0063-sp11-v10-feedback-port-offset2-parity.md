---
id: adr-0063-sp11-v10-feedback-port-offset2-parity
title: "ADR0063: SP11 Feedback-Port Offset2 Boot Param (Windows Offset2 Parity)"
# prettier-ignore
description: Architecture Decision Record (ADR) for enabling the SoundWire feedback-port Offset2 parity from kernel commit 5cf86f71 through the opt-in soundwire_qcom.sp11_feedback_active_offset2_zero module parameter on the SP11 GRUB command line, eliminating volume-change pops and stream-start static on the 7.2.0-jg-0sp11v10 line.
---

> **Current operator notice (2026-08-30):** Former broad installer and audio
> migration helper names below are preserved as evidence of the v10 transition
> and are non-prescriptive. Use `kernel build`, `kernel preflight`,
> `kernel install`, `userspace install audio`, `userspace status`, and
> `doctor hardware audio`; see
> [CLI ADR010](../../cli/linux-armer/docs/adr/adr-010-native-cli-workflow-migration.md).
> This notice does not alter the specific hardware result recorded here.

# ADR0063: SP11 Feedback-Port Offset2 Boot Param (Windows Offset2 Parity)

## Status

Accepted and hardware-verified (2026-08-24). Booting
`7.2.0-jg-0sp11v10-qcom-x1e` on the X1E80100 OLED device with
`soundwire_qcom.sp11_feedback_active_offset2_zero=1` eliminates both
volume-change pops and stream-start static. The symptoms were previously
audible without the parameter: intermittent volume-change pops on v9 and
occasional static immediately before system sounds on v10. `/proc/cmdline`
carries the parameter, and
`/sys/module/soundwire_qcom/parameters/sp11_feedback_active_offset2_zero`
reads `Y`.

## Context

geocausa's Golden v32/v33 audio parity port, on kernel branch
`sp11/integration-7.2.x-geocausa-sound` in
[PR #17](https://github.com/ooaklee/linux_ms_dev_kit-sp11/pull/17), already
integrated the feedback-port Offset2 handling in commit `5cf86f71`. The WSA
protection-clock parity was likewise already present in commit `e72bffcb10ef`.
The Offset2 path is opt-in, however: the
`sp11_feedback_active_offset2_zero` module parameter defaults off.

geocausa's reference GRUB entries in
`deploy/golden-v32/install-grub-entry.sh` and
`deploy/golden-v33/install-grub-entry.sh` in `SP11X1e-audio` pass
`soundwire_qcom.sp11_feedback_active_offset2_zero=1`. The OE install and
migration paths did not carry that reference setting. On hardware without the
parameter, intermittent volume-change pops were audible on v9, and occasional
static immediately before system sounds was audible on v10.

## Decision

- Enable `soundwire_qcom.sp11_feedback_active_offset2_zero=1` on the SP11 GRUB
  command line as part of the native audio configuration.
- Make `scripts/install-sp11-support.sh` emit the parameter in
  `/etc/default/grub.d/99-surface-pro-11.cfg` for new installations.
- Make `scripts/sp11-audio-migrate-to-native.sh` set the parameter on existing
  machines. Its `ensure_boot_param` path is idempotent, creates a backup, runs
  `update-grub`, and participates in rollback. If the SP11 `grub.d` file is
  absent, it creates
  `/etc/default/grub.d/98-sp11-native-audio-offset2.cfg` instead.
- Require no new kernel commits for the v11 round. The protection-clock and
  Offset2 parity changes were already on the branch; only the reference boot
  parameter was missing.
- Apply the parameter at module load. It therefore takes effect on any SP11
  kernel carrying commit `5cf86f71`.

## Consequences

- Volume-change pops and stream-start static are eliminated, hardware-verified
  on the v10 kernel line.
- The boot parameter is required on every SP11 boot. Verify it with
  `grep soundwire_qcom /proc/cmdline` and confirm that
  `/sys/module/soundwire_qcom/parameters/sp11_feedback_active_offset2_zero`
  reads `Y`.
- Rollback is a one-line GRUB edit followed by `update-grub`, or the migration
  script's restore path.
- Unrelated kernel configurations are unaffected; the module behavior changes
  only when the parameter is present.
- Migration tooling is recorded in
  [a864d31](https://github.com/ooaklee/linux-surface-pro-11-oe/commit/a864d31)
  and
  [0412e3e](https://github.com/ooaklee/linux-surface-pro-11-oe/commit/0412e3e).
  The kernel parity port remains tracked in
  [PR #17](https://github.com/ooaklee/linux_ms_dev_kit-sp11/pull/17).

## Related ADRs

- [ADR-0062](adr-0062-sp11-7-2-0-jg-0sp11v9-golden-v32-audio-line.md) —
  the v9 Golden-v32 line this decision builds on
