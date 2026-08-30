package application

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io/fs"
	"os"
	"path"
	"sort"
	"strconv"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/bluetoothmgmt"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/handoff"
)

const (
	// applicationPlanDomain separates confirmation identity from payload digests.
	applicationPlanDomain = "linux-armer.windows-handoff/application-plan/v1\x00"
	// applicationConfirmationPrefix prevents blanket affirmative confirmation.
	applicationConfirmationPrefix = "apply "
)

// desiredSource identifies how private desired bytes are obtained at mutation.
type desiredSource string

const (
	// sourceStatic uses reviewed in-memory bytes such as a unit or private config.
	sourceStatic desiredSource = "static"
	// sourceFirmware reopens a compiled record through the private material handle.
	sourceFirmware desiredSource = "firmware"
	// sourceBinary reopens the exact current linux-armer executable.
	sourceBinary desiredSource = "binary"
)

// desiredAction retains private mutation authority outside JSON and formatting.
type desiredAction struct {
	// change is the only deliberately redacted public view.
	change Change
	// mode is the exact desired regular-file permission mode.
	mode fs.FileMode
	// source selects one closed byte source for file actions.
	source desiredSource
	// sourceID selects one compiled firmware record without accepting a path.
	sourceID string
	// data contains fixed or private configuration bytes and must never be formatted.
	data []byte
	// sha256 is the exact desired file digest retained privately.
	sha256 string
	// size is the exact desired file size retained privately.
	size int64
	// linkTarget is a compiled relative target for symbolic-link actions.
	linkTarget string
	// observedSHA256 privately binds the complete current target object state.
	observedSHA256 string
}

// bluetoothConfig is the strict private file consumed by the hidden command.
type bluetoothConfig struct {
	// SchemaVersion selects the exact private local configuration shape.
	SchemaVersion int `json:"schema_version"`
	// ControllerSelector identifies the compiled physical-radio policy without
	// trusting boot-order-dependent HCI numbering.
	ControllerSelector bluetoothmgmt.ControllerSelector `json:"controller_selector"`
	// Address is private and must never be returned by delivery code.
	Address handoff.BluetoothAddress `json:"address"`
}

// bluetoothUnit contains no private value and invokes only the fixed hidden command.
var bluetoothUnit = []byte(`[Unit]
Description=Apply the private Surface Pro 11 Bluetooth controller address
ConditionPathExists=/etc/linux-armer/private/bluetooth-address.json
Wants=bluetooth.service
Before=bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/linux-armer/linux-armer handoff internal-bluetooth-address
TimeoutStartSec=9min
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=bluetooth.service
`)

// Plan revalidates the private store and same-device identity before examining
// only compiled target destinations without changing any filesystem object.
func (manager *Manager) Plan(ctx context.Context, request Request) (Plan, error) {
	if manager == nil {
		return Plan{}, errors.New("hand-off application manager is not initialised")
	}
	if ctx == nil {
		return Plan{}, errors.New("plan private hand-off application: context is nil")
	}
	if err := ctx.Err(); err != nil {
		return Plan{}, err
	}
	identityRoot, err := resolveExplicitRoot(request.IdentityRoot, "identity root", true)
	if err != nil {
		return Plan{}, err
	}
	targetRoot, err := resolveExplicitRoot(request.TargetRoot, "target root", false)
	if err != nil {
		return Plan{}, err
	}
	material, err := handoff.RevalidateForApplication(ctx, request.StoreRoot, request.ID)
	if err != nil {
		return Plan{}, err
	}
	contract := material.PrivateContract()
	if err := verifyDeviceBinding(ctx, identityRoot, contract); err != nil {
		return Plan{}, err
	}
	features, err := selectFeatures(request.Features, contract)
	if err != nil {
		return Plan{}, err
	}
	policy := request.ADSPPolicy
	if containsFeature(features, FeatureFirmware) {
		policy, err = ParseADSPPolicy(string(policy))
		if err != nil {
			return Plan{}, err
		}
	} else if policy != "" {
		return Plan{}, errors.New("aDSP policy is valid only when firmware is selected")
	}
	binary := binaryArtifact{compatible: true}
	if containsFeature(features, FeatureBluetooth) {
		binary, err = manager.inspectCurrentBinary(ctx)
		if err != nil {
			return Plan{}, err
		}
	}
	desired, err := buildDesiredActions(contract, features, policy, binary)
	if err != nil {
		return Plan{}, err
	}
	target, err := os.OpenRoot(targetRoot)
	if err != nil {
		return Plan{}, fmt.Errorf("open target root: %w", err)
	}
	defer target.Close()
	changes := make([]Change, 0, len(desired))
	required := 0
	for index := range desired {
		matches, observation, inspectErr := inspectTarget(ctx, target, desired[index])
		if inspectErr != nil {
			return Plan{}, inspectErr
		}
		desired[index].observedSHA256 = observation
		desired[index].change.Required = !matches
		changes = append(changes, desired[index].change)
		if !matches {
			required++
		}
	}
	plan := Plan{
		ID: material.ID(), IdentityRoot: identityRoot, TargetRoot: targetRoot,
		Features: append([]Feature(nil), features...), ADSPPolicy: policy,
		Changes: changes, RequiredChanges: required,
		HostBinaryCompatible: binary.compatible,
		storeRoot:            request.StoreRoot, material: material, desired: desired, binary: binary,
	}
	plan.PlanSHA256 = digestPlan(plan)
	plan.Confirmation = applicationConfirmationPrefix + plan.ID + " plan " + plan.PlanSHA256 + " to " + plan.TargetRoot
	return plan, nil
}

// selectFeatures validates availability, de-duplicates input, and preserves a
// canonical order so omission is explicit and plan identity stays stable.
func selectFeatures(requested []Feature, contract handoff.Contract) ([]Feature, error) {
	available := map[Feature]bool{
		FeatureFirmware:  contract.PlatformFirmware.Included,
		FeatureBluetooth: contract.BluetoothPublicAddress.Included,
	}
	if len(requested) == 0 {
		selected := make([]Feature, 0, len(featureOrder))
		for _, feature := range featureOrder {
			if available[feature] {
				selected = append(selected, feature)
			}
		}
		return selected, nil
	}
	wanted := make(map[Feature]bool, len(requested))
	for _, feature := range requested {
		parsed, err := ParseFeature(string(feature))
		if err != nil {
			return nil, err
		}
		if !available[parsed] {
			return nil, fmt.Errorf("selected %s material is explicitly absent from this hand-off", parsed)
		}
		wanted[parsed] = true
	}
	selected := make([]Feature, 0, len(wanted))
	for _, feature := range featureOrder {
		if wanted[feature] {
			selected = append(selected, feature)
		}
	}
	return selected, nil
}

// containsFeature reports membership in one canonical feature slice.
func containsFeature(features []Feature, wanted Feature) bool {
	for _, feature := range features {
		if feature == wanted {
			return true
		}
	}
	return false
}

// buildDesiredActions derives all destinations from compiled policy rather than
// trusting contract paths as mutation instructions.
func buildDesiredActions(contract handoff.Contract, features []Feature, policy ADSPPolicy, binary binaryArtifact) ([]desiredAction, error) {
	actions := make([]desiredAction, 0, 18)
	if containsFeature(features, FeatureFirmware) {
		records := make(map[string]handoff.FirmwareFileRecord, len(contract.PlatformFirmware.Files))
		for _, record := range contract.PlatformFirmware.Files {
			records[record.ID] = record
		}
		for _, compiled := range handoff.FirmwarePolicies() {
			record, found := records[compiled.ID]
			if !found {
				return nil, fmt.Errorf("compiled firmware %s is absent after private revalidation", compiled.ID)
			}
			destination := compiled.Destination
			if compiled.ID == "adsp-dtb" && policy == ADSPDisabled {
				destination = DisabledADSPPath
			}
			actions = append(actions, desiredAction{
				change: Change{ID: "firmware-" + compiled.ID, Feature: FeatureFirmware, Path: destination, Kind: ChangeFile},
				mode:   0o644, source: sourceFirmware, sourceID: compiled.ID,
				sha256: record.SHA256, size: record.Size,
			})
		}
		inactivePath := DisabledADSPPath
		if policy == ADSPDisabled {
			inactivePath = ActiveADSPPath
		}
		actions = append(actions,
			desiredAction{change: Change{ID: "firmware-adsp-inactive-path", Feature: FeatureFirmware, Path: inactivePath, Kind: ChangeAbsent}},
			desiredAction{change: Change{ID: "firmware-denali-gpu-link", Feature: FeatureFirmware, Path: DenaliGPULinkPath, Kind: ChangeSymlink}, linkTarget: denaliGPULinkTarget},
		)
	}
	if containsFeature(features, FeatureBluetooth) {
		if contract.BluetoothPublicAddress.Address == nil {
			return nil, errors.New("private Bluetooth material is incomplete after revalidation")
		}
		configBytes, err := json.Marshal(bluetoothConfig{
			SchemaVersion: 2, ControllerSelector: bluetoothmgmt.SurfacePro11WCN7850UART,
			Address: *contract.BluetoothPublicAddress.Address,
		})
		if err != nil {
			return nil, errors.New("encode private Bluetooth configuration")
		}
		configBytes = append(configBytes, '\n')
		actions = append(actions,
			staticFileAction("bluetooth-private-config", FeatureBluetooth, BluetoothConfigPath, 0o600, configBytes),
			desiredAction{
				change: Change{ID: "bluetooth-linux-armer-binary", Feature: FeatureBluetooth, Path: InstalledBinaryPath, Kind: ChangeFile},
				mode:   0o755, source: sourceBinary, sha256: binary.sha256, size: binary.size,
			},
			staticFileAction("bluetooth-systemd-unit", FeatureBluetooth, BluetoothUnitPath, 0o644, bluetoothUnit),
			desiredAction{change: Change{ID: "bluetooth-systemd-wants-link", Feature: FeatureBluetooth, Path: BluetoothWantsPath, Kind: ChangeSymlink}, linkTarget: bluetoothWantsTarget},
		)
	}
	for _, action := range actions {
		if err := validateCompiledPath(action.change.Path); err != nil {
			return nil, err
		}
	}
	return actions, nil
}

// staticFileAction constructs one fixed or private in-memory file action.
func staticFileAction(identifier string, feature Feature, destination string, mode fs.FileMode, data []byte) desiredAction {
	digest := sha256.Sum256(data)
	return desiredAction{
		change: Change{ID: identifier, Feature: feature, Path: destination, Kind: ChangeFile},
		mode:   mode, source: sourceStatic, data: append([]byte(nil), data...),
		sha256: hex.EncodeToString(digest[:]), size: int64(len(data)),
	}
}

// validateCompiledPath rejects any path that is not a canonical relative target.
func validateCompiledPath(value string) error {
	if value == "" || path.IsAbs(value) || strings.Contains(value, "\\") || strings.ContainsRune(value, '\x00') || path.Clean(value) != value {
		return errors.New("compiled hand-off application path is not canonical")
	}
	for _, component := range strings.Split(value, "/") {
		if component == "" || component == "." || component == ".." {
			return errors.New("compiled hand-off application path is not canonical")
		}
	}
	return nil
}

// digestPlan binds revalidated private material and current-target decisions
// into a public checkpoint without returning the underlying values.
func digestPlan(plan Plan) string {
	digest := sha256.New()
	writeDigestField(digest, applicationPlanDomain)
	writeDigestField(digest, plan.ID)
	writeDigestField(digest, plan.material.ClosedSetSHA256())
	writeDigestField(digest, plan.IdentityRoot)
	writeDigestField(digest, plan.TargetRoot)
	writeDigestField(digest, string(plan.ADSPPolicy))
	writeDigestField(digest, plan.binary.sha256)
	for _, feature := range plan.Features {
		writeDigestField(digest, string(feature))
	}
	for _, action := range plan.desired {
		writeDigestField(digest, action.change.ID)
		writeDigestField(digest, string(action.change.Feature))
		writeDigestField(digest, action.change.Path)
		writeDigestField(digest, string(action.change.Kind))
		writeDigestField(digest, strconv.FormatBool(action.change.Required))
		writeDigestField(digest, strconv.FormatUint(uint64(action.mode.Perm()), 8))
		writeDigestField(digest, action.sha256)
		writeDigestField(digest, strconv.FormatInt(action.size, 10))
		writeDigestField(digest, action.linkTarget)
		writeDigestField(digest, action.observedSHA256)
	}
	return hex.EncodeToString(digest.Sum(nil))
}

// writeDigestField adds one length-prefixed value without concatenation ambiguity.
func writeDigestField(digest hash.Hash, value string) {
	_, _ = digest.Write([]byte(strconv.Itoa(len(value))))
	_, _ = digest.Write([]byte{':'})
	_, _ = digest.Write([]byte(value))
}

// cloneFeatures returns a defensive feature slice in public result values.
func cloneFeatures(features []Feature) []Feature {
	return append([]Feature(nil), features...)
}

// sortedRequiredChangeIDs returns deterministic identifiers for receipt metadata.
func sortedRequiredChangeIDs(actions []desiredAction) []string {
	identifiers := make([]string, 0, len(actions))
	for _, action := range actions {
		if action.change.Required {
			identifiers = append(identifiers, action.change.ID)
		}
	}
	sort.Strings(identifiers)
	return identifiers
}
