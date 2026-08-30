// Package application plans and applies private, same-device Windows hand-off
// material through a rollback-capable installed-system transaction.
package application

import (
	"context"
	"fmt"
	"runtime"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/handoff"
)

// Feature identifies one independently selectable private application area.
type Feature string

const (
	// FeatureFirmware selects the complete compiled eleven-file firmware policy.
	FeatureFirmware Feature = "firmware"
	// FeatureBluetooth selects private address configuration and boot integration.
	FeatureBluetooth Feature = "bluetooth"
)

// featureOrder fixes canonical plan and confirmation ordering.
var featureOrder = []Feature{FeatureFirmware, FeatureBluetooth}

// ADSPPolicy records the explicit boot-medium decision for the aDSP DTB.
type ADSPPolicy string

const (
	// ADSPEnabled installs the aDSP DTB at its active installed-NVMe path.
	ADSPEnabled ADSPPolicy = "enabled"
	// ADSPDisabled installs the aDSP DTB at its inactive live-USB-safe path.
	ADSPDisabled ADSPPolicy = "disabled"
)

const (
	// ReceiptDirectory is the fixed target-relative private receipt directory.
	ReceiptDirectory = "var/lib/linux-armer/handoff/receipts"
	// BluetoothConfigPath is the fixed target-relative private address file.
	BluetoothConfigPath = "etc/linux-armer/private/bluetooth-address.json"
	// InstalledBinaryPath is the fixed target-relative Linux ARM64 helper copy.
	InstalledBinaryPath = "usr/libexec/linux-armer/linux-armer"
	// BluetoothUnitPath is the fixed target-relative systemd unit.
	BluetoothUnitPath = "etc/systemd/system/linux-armer-sp11-bluetooth-address.service"
	// BluetoothWantsPath is the fixed target-relative dependency link.
	BluetoothWantsPath = "etc/systemd/system/bluetooth.service.wants/linux-armer-sp11-bluetooth-address.service"
	// DenaliGPULinkPath is the fixed compatibility link below the Denali directory.
	DenaliGPULinkPath = "lib/firmware/qcom/x1e80100/microsoft/Denali/qcdxkmsuc8380.mbn"
	// ActiveADSPPath is the canonical enabled aDSP DTB path.
	ActiveADSPPath = "lib/firmware/qcom/x1e80100/microsoft/Denali/adsp_dtb.mbn"
	// DisabledADSPPath is the canonical live-USB-safe aDSP DTB path.
	DisabledADSPPath = ActiveADSPPath + ".disabled"
)

const (
	// bluetoothUnitName is fixed so no contract field becomes executable input.
	bluetoothUnitName = "linux-armer-sp11-bluetooth-address.service"
	// denaliGPULinkTarget is the reviewed root-relative firmware bridge.
	denaliGPULinkTarget = "../qcdxkmsuc8380.mbn"
	// bluetoothWantsTarget links the dependency directory to the fixed unit.
	bluetoothWantsTarget = "../" + bluetoothUnitName
)

// ChangeKind describes the intended final filesystem object without its bytes.
type ChangeKind string

const (
	// ChangeFile installs one regular file with a compiled mode.
	ChangeFile ChangeKind = "file"
	// ChangeSymlink installs one fixed relative symbolic link.
	ChangeSymlink ChangeKind = "symlink"
	// ChangeAbsent removes a mutually exclusive policy path transactionally.
	ChangeAbsent ChangeKind = "absent"
)

// Change is the redacted, stable view of one planned target operation.
type Change struct {
	// ID is a compiled action identifier that contains no private value.
	ID string `json:"id"`
	// Feature groups the operation by explicit feature selection.
	Feature Feature `json:"feature"`
	// Path is one compiled target-relative destination.
	Path string `json:"path"`
	// Kind is the intended final filesystem object.
	Kind ChangeKind `json:"kind"`
	// Required reports whether the current target differs from the plan.
	Required bool `json:"required"`
}

// Request contains explicit roots and selectors for one read-only plan.
type Request struct {
	// StoreRoot is the private content-addressed hand-off store.
	StoreRoot string
	// ID is the exact imported manifest content address.
	ID string
	// IdentityRoot supplies live SMBIOS identity independently of the target root.
	IdentityRoot string
	// TargetRoot is the installed system or live filesystem to modify later.
	TargetRoot string
	// Features selects a subset; empty selects every included contract feature.
	Features []Feature
	// ADSPPolicy is mandatory whenever firmware is selected.
	ADSPPolicy ADSPPolicy
}

// Plan is an immutable, redacted checkpoint for one exact store, identity,
// target, feature, policy, binary, and current-target state.
type Plan struct {
	// ID is the imported hand-off content address.
	ID string `json:"id"`
	// IdentityRoot is the resolved root used only for same-device verification.
	IdentityRoot string `json:"identity_root"`
	// TargetRoot is the separately resolved installation destination.
	TargetRoot string `json:"target_root"`
	// Features records canonical selected-feature order.
	Features []Feature `json:"features"`
	// ADSPPolicy records the explicit firmware boot-medium policy when applicable.
	ADSPPolicy ADSPPolicy `json:"adsp_policy,omitempty"`
	// Changes contains only compiled paths and redacted action identifiers.
	Changes []Change `json:"changes"`
	// RequiredChanges counts operations that would alter the target.
	RequiredChanges int `json:"required_changes"`
	// HostBinaryCompatible reports whether Bluetooth mutation can copy this process.
	HostBinaryCompatible bool `json:"host_binary_compatible"`
	// PlanSHA256 binds private revalidation and every public plan parameter.
	PlanSHA256 string `json:"plan_sha256"`
	// Confirmation is the exact ID-, plan-, and target-root-bound phrase.
	Confirmation string `json:"confirmation"`
	// storeRoot retains the resolved private store for mandatory replanning.
	storeRoot string
	// material retains an opaque private handle and must never be formatted.
	material handoff.ApplicationMaterial
	// desired retains private bytes and digests outside JSON delivery.
	desired []desiredAction
	// binary retains the exact current executable snapshot.
	binary binaryArtifact
}

// String returns a redacted plan summary rather than private internal fields.
func (plan Plan) String() string {
	return fmt.Sprintf("handoff application plan %s with %d required changes", plan.ID, plan.RequiredChanges)
}

// GoString returns the same redacted plan summary for diagnostic formatting.
func (plan Plan) GoString() string {
	return plan.String()
}

// Result reports transaction completion without private payload or identity data.
type Result struct {
	// ID is the applied hand-off content address.
	ID string `json:"id"`
	// PlanSHA256 identifies the exact reviewed transaction.
	PlanSHA256 string `json:"plan_sha256"`
	// TargetRoot is the resolved destination bound by confirmation.
	TargetRoot string `json:"target_root"`
	// Features records the applied feature subset.
	Features []Feature `json:"features"`
	// Changed is the number of target objects changed by this invocation.
	Changed int `json:"changed"`
	// Applied reports that the target matches the complete selected policy.
	Applied bool `json:"applied"`
	// AlreadyApplied reports that no mutation was necessary.
	AlreadyApplied bool `json:"already_applied"`
	// ReceiptID identifies the durable private rollback record without its contents.
	ReceiptID string `json:"receipt_id,omitempty"`
}

// RestorePlan is a redacted checkpoint for recovering or deliberately rolling
// back one exact durable private receipt at its original target root.
type RestorePlan struct {
	// ReceiptID identifies the private local receipt without returning its body.
	ReceiptID string `json:"receipt_id"`
	// TargetRoot is the separately resolved destination recorded by the receipt.
	TargetRoot string `json:"target_root"`
	// ReceiptState reports only the non-private transaction phase.
	ReceiptState string `json:"receipt_state"`
	// RequiredChanges counts target objects or staging artefacts to restore.
	RequiredChanges int `json:"required_changes"`
	// RecoverySHA256 binds the complete private receipt and observed target state.
	RecoverySHA256 string `json:"recovery_sha256"`
	// Confirmation is the exact receipt-, recovery-, and target-bound phrase.
	Confirmation string `json:"confirmation"`
	// receipt retains the strictly validated private recovery journal.
	receipt privateReceipt
}

// String returns a redacted recovery summary without receipt-private fields.
func (plan RestorePlan) String() string {
	return fmt.Sprintf("hand-off restore plan %s with %d required changes", plan.ReceiptID, plan.RequiredChanges)
}

// GoString returns the same redacted recovery summary for diagnostic formatting.
func (plan RestorePlan) GoString() string {
	return plan.String()
}

// RestoreResult reports recovery completion without private journal contents.
type RestoreResult struct {
	// ReceiptID identifies the durable journal that was restored.
	ReceiptID string `json:"receipt_id"`
	// TargetRoot is the resolved restored destination.
	TargetRoot string `json:"target_root"`
	// Restored reports that rollback is durably complete.
	Restored bool `json:"restored"`
	// AlreadyRestored reports that no target mutation was necessary.
	AlreadyRestored bool `json:"already_restored"`
	// Changed counts receipt actions returned to their original state.
	Changed int `json:"changed"`
}

// Configuration supplies narrow process properties for construction and tests.
type Configuration struct {
	// ExecutablePath overrides the current executable source when non-empty.
	ExecutablePath string
	// RuntimeGOOS overrides runtime.GOOS when non-empty.
	RuntimeGOOS string
	// RuntimeGOARCH overrides runtime.GOARCH when non-empty.
	RuntimeGOARCH string
	// EffectiveUID supplies the current effective user identifier.
	EffectiveUID func() int
}

// Manager coordinates private revalidation, planning, and target transactions.
type Manager struct {
	// executablePath identifies the exact binary considered for Bluetooth support.
	executablePath string
	// runtimeGOOS records the current executable operating system.
	runtimeGOOS string
	// runtimeGOARCH records the current executable architecture.
	runtimeGOARCH string
	// effectiveUID defers the mutation privilege check until it is necessary.
	effectiveUID func() int
	// hooks supplies deterministic failure points to package tests only.
	hooks transactionHooks
}

// New constructs an application manager without inspecting roots or private data.
func New(configuration *Configuration) *Manager {
	manager := &Manager{
		runtimeGOOS:   runtime.GOOS,
		runtimeGOARCH: runtime.GOARCH,
		effectiveUID:  effectiveUserID,
	}
	if configuration == nil {
		return manager
	}
	manager.executablePath = configuration.ExecutablePath
	if configuration.RuntimeGOOS != "" {
		manager.runtimeGOOS = configuration.RuntimeGOOS
	}
	if configuration.RuntimeGOARCH != "" {
		manager.runtimeGOARCH = configuration.RuntimeGOARCH
	}
	if configuration.EffectiveUID != nil {
		manager.effectiveUID = configuration.EffectiveUID
	}
	return manager
}

// Workflow is the delivery layer's complete application-manager boundary.
type Workflow interface {
	// Plan revalidates private material and returns a read-only checkpoint.
	Plan(context.Context, Request) (Plan, error)
	// Apply revalidates an unchanged plan and performs a confirmed transaction.
	Apply(context.Context, Plan, string) (Result, error)
}

// RestoreWorkflow is the delivery layer's private receipt-recovery boundary.
type RestoreWorkflow interface {
	// PlanRestore strictly revalidates one receipt and current target state.
	PlanRestore(context.Context, string, string) (RestorePlan, error)
	// Restore revalidates and rolls back one exactly confirmed receipt.
	Restore(context.Context, RestorePlan, string) (RestoreResult, error)
}

// ParseFeature validates one case-insensitive application feature selector.
func ParseFeature(value string) (Feature, error) {
	feature := Feature(strings.ToLower(strings.TrimSpace(value)))
	for _, candidate := range featureOrder {
		if feature == candidate {
			return feature, nil
		}
	}
	return "", fmt.Errorf("unsupported hand-off application feature %q; expected firmware or bluetooth", value)
}

// ParseADSPPolicy validates the explicit installed-NVMe or live-USB policy.
func ParseADSPPolicy(value string) (ADSPPolicy, error) {
	policy := ADSPPolicy(strings.ToLower(strings.TrimSpace(value)))
	if policy != ADSPEnabled && policy != ADSPDisabled {
		return "", errorsNewADSPPolicy()
	}
	return policy, nil
}

// errorsNewADSPPolicy returns one shared non-private policy validation error.
func errorsNewADSPPolicy() error {
	return fmt.Errorf("aDSP policy must be explicit: enabled for installed NVMe or disabled for live USB")
}
