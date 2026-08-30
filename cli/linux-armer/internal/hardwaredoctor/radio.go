package hardwaredoctor

import (
	"context"
	"path"
	"regexp"
	"strings"
)

const (
	// maximumRFKillDevices bounds the kernel radio-switch inventory.
	maximumRFKillDevices = 64
)

// rfkillEntryPattern admits only canonical kernel rfkill entry names.
var rfkillEntryPattern = regexp.MustCompile(`^rfkill[0-9]{1,4}$`)

// radioBlockState aggregates one radio type without retaining device names.
type radioBlockState struct {
	// observed is the number of well-formed matching entries.
	observed int
	// softBlocked is the number blocked by software policy.
	softBlocked int
	// hardBlocked is the number blocked by hardware state.
	hardBlocked int
	// incomplete records malformed or unreadable matching entries.
	incomplete bool
}

// inspectRadioBlock turns bounded sysfs state into one redacted feature check.
func (doctor *Doctor) inspectRadioBlock(ctx context.Context, feature Feature, radioType, checkID string) Check {
	state := doctor.readRadioBlock(ctx, radioType)
	switch {
	case state.observed == 0 && state.incomplete:
		return Check{ID: checkID, Feature: feature, Evidence: EvidenceRuntime, State: StateUnavailable, Required: true, Detail: "kernel radio-block state could not be inspected safely"}
	case state.observed == 0:
		return Check{ID: checkID, Feature: feature, Evidence: EvidenceRuntime, State: StateFail, Required: true, Detail: "the kernel exposes no radio-block state for this device"}
	case state.hardBlocked > 0:
		return Check{ID: checkID, Feature: feature, Evidence: EvidenceRuntime, State: StateFail, Required: true, Detail: "the device is hardware-blocked by the current rfkill state", Remediation: "review the loaded device tree and running Surface kernel; this doctor will not alter rfkill state"}
	case state.softBlocked > 0:
		return Check{ID: checkID, Feature: feature, Evidence: EvidenceRuntime, State: StateWarn, Required: false, Detail: "the device is software-blocked by the current rfkill state", Remediation: "clear the radio block through an authorised system control, then rerun the read-only doctor"}
	case state.incomplete:
		return Check{ID: checkID, Feature: feature, Evidence: EvidenceRuntime, State: StateWarn, Required: false, Detail: "an unblocked radio is present, but additional rfkill entries were not fully observable"}
	default:
		return Check{ID: checkID, Feature: feature, Evidence: EvidenceRuntime, State: StatePass, Required: true, Detail: "the device is neither software-blocked nor hardware-blocked"}
	}
}

// readRadioBlock aggregates only type and binary block flags from sysfs.
func (doctor *Doctor) readRadioBlock(ctx context.Context, wantedType string) radioBlockState {
	entries, err := doctor.filesystem.ReadDir(ctx, "/sys/class/rfkill", maximumRFKillDevices)
	if err != nil {
		return radioBlockState{incomplete: true}
	}
	state := radioBlockState{}
	for _, entry := range entries {
		if !rfkillEntryPattern.MatchString(entry.Name) {
			continue
		}
		base := path.Join("/sys/class/rfkill", entry.Name)
		radioType, typeErr := doctor.filesystem.ReadFile(ctx, path.Join(base, "type"), maximumSysfsValueBytes)
		if typeErr != nil {
			state.incomplete = true
			continue
		}
		if strings.TrimSpace(string(radioType)) != wantedType {
			continue
		}
		soft, softErr := doctor.filesystem.ReadFile(ctx, path.Join(base, "soft"), maximumSysfsValueBytes)
		hard, hardErr := doctor.filesystem.ReadFile(ctx, path.Join(base, "hard"), maximumSysfsValueBytes)
		if softErr != nil || hardErr != nil {
			state.incomplete = true
			continue
		}
		softValue := strings.TrimSpace(string(soft))
		hardValue := strings.TrimSpace(string(hard))
		if (softValue != "0" && softValue != "1") || (hardValue != "0" && hardValue != "1") {
			state.incomplete = true
			continue
		}
		state.observed++
		if softValue == "1" {
			state.softBlocked++
		}
		if hardValue == "1" {
			state.hardBlocked++
		}
	}
	return state
}
