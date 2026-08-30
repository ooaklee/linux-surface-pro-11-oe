package application

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"unicode"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/handoff"
)

const (
	// receiptSchemaVersion selects the only private transaction journal shape.
	receiptSchemaVersion = 1
	// receiptKind distinguishes this private journal from public result JSON.
	receiptKind = "linux-armer.windows-handoff-application-receipt"
	// maximumReceiptBytes bounds strict local journal decoding.
	maximumReceiptBytes int64 = 1 << 20
)

// receiptState identifies the durable phase of an application transaction.
type receiptState string

const (
	// receiptPrepared records all intended paths before payload mutation begins.
	receiptPrepared receiptState = "prepared"
	// receiptApplying records that at least one target operation has started.
	receiptApplying receiptState = "applying"
	// receiptCommitted records complete post-write and source revalidation.
	receiptCommitted receiptState = "committed"
	// receiptRollingBack records bounded failure recovery in progress.
	receiptRollingBack receiptState = "rolling-back"
	// receiptRolledBack records complete restoration of the pre-transaction state.
	receiptRolledBack receiptState = "rolled-back"
)

// originalKind describes the safe pre-transaction target type.
type originalKind string

const (
	// originalAbsent records that no object existed at the compiled path.
	originalAbsent originalKind = "absent"
	// originalFile records a bounded regular file moved to same-filesystem backup.
	originalFile originalKind = "file"
	// originalSymlink records a symbolic link moved without following it.
	originalSymlink originalKind = "symlink"
)

// privateReceipt is a mode-0600 local rollback journal and is never returned by
// command output because it contains private byte fingerprints.
type privateReceipt struct {
	// SchemaVersion selects the strict receipt decoder.
	SchemaVersion int `json:"schema_version"`
	// Kind identifies the private journal contract.
	Kind string `json:"kind"`
	// ReceiptID is the plan digest and fixed receipt filename.
	ReceiptID string `json:"receipt_id"`
	// HandoffID is the selected imported manifest content address.
	HandoffID string `json:"handoff_id"`
	// PlanSHA256 binds this receipt to its exact reviewed plan.
	PlanSHA256 string `json:"plan_sha256"`
	// TargetRoot records the separately resolved target for local restoration.
	TargetRoot string `json:"target_root"`
	// State records the durable transaction phase.
	State receiptState `json:"state"`
	// CreatedDirectories lists transaction-created payload parents deepest-last.
	CreatedDirectories []string `json:"created_directories"`
	// Actions records recovery material in application order.
	Actions []receiptAction `json:"actions"`
}

// String returns a redacted journal summary without private fingerprints.
func (receipt privateReceipt) String() string {
	return fmt.Sprintf("private hand-off receipt %s in state %s", receipt.ReceiptID, receipt.State)
}

// GoString returns the same redacted journal summary for diagnostics.
func (receipt privateReceipt) GoString() string {
	return receipt.String()
}

// receiptAction records enough local state to restore one compiled destination.
type receiptAction struct {
	// ID is the compiled non-private action identifier.
	ID string `json:"id"`
	// Path is the compiled target-relative destination.
	Path string `json:"path"`
	// DesiredKind is the reviewed final object kind.
	DesiredKind ChangeKind `json:"desired_kind"`
	// DesiredMode is the reviewed regular-file permission mode.
	DesiredMode uint32 `json:"desired_mode,omitempty"`
	// DesiredSHA256 is retained only in this private local journal.
	DesiredSHA256 string `json:"desired_sha256,omitempty"`
	// DesiredSize is retained only in this private local journal.
	DesiredSize int64 `json:"desired_size,omitempty"`
	// DesiredLinkTarget is a fixed relative target for link verification.
	DesiredLinkTarget string `json:"desired_link_target,omitempty"`
	// Required records that this action differed during the reviewed plan.
	Required bool `json:"required"`
	// OriginalKind records the safely inspected pre-transaction type.
	OriginalKind originalKind `json:"original_kind"`
	// OriginalMode records pre-transaction regular-file permissions.
	OriginalMode uint32 `json:"original_mode,omitempty"`
	// OriginalSHA256 verifies a retained regular-file backup.
	OriginalSHA256 string `json:"original_sha256,omitempty"`
	// OriginalSize verifies a retained regular-file backup.
	OriginalSize int64 `json:"original_size,omitempty"`
	// OriginalLinkTarget verifies a retained symbolic-link backup.
	OriginalLinkTarget string `json:"original_link_target,omitempty"`
	// BackupPath is a same-parent, same-filesystem quarantine name.
	BackupPath string `json:"backup_path,omitempty"`
	// StagePath is a same-parent unpublished desired-object name.
	StagePath string `json:"stage_path,omitempty"`
	// BackupCreated records successful durable isolation of an original object.
	BackupCreated bool `json:"backup_created"`
	// Applied records successful durable publication of the desired object.
	Applied bool `json:"applied"`
}

// receiptPath returns the fixed target-relative receipt filename.
func receiptPath(receiptID string) string {
	return path.Join(ReceiptDirectory, receiptID+".json")
}

// ensureReceiptDirectory creates only the fixed private administration path and
// verifies the final directory mode before any payload operation.
func ensureReceiptDirectory(root *os.Root) error {
	if err := root.MkdirAll(ReceiptDirectory, 0o700); err != nil {
		return fmt.Errorf("create private hand-off receipt directory: %w", err)
	}
	if err := root.Chmod(ReceiptDirectory, 0o700); err != nil {
		return fmt.Errorf("protect private hand-off receipt directory: %w", err)
	}
	info, err := root.Stat(ReceiptDirectory)
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0o700 {
		return errors.New("private hand-off receipt directory is not a protected directory")
	}
	return syncRootDirectory(root, ReceiptDirectory)
}

// writeReceipt atomically replaces one private journal and flushes its directory.
func writeReceipt(root *os.Root, receipt privateReceipt) error {
	encoded, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return errors.New("encode private hand-off application receipt")
	}
	encoded = append(encoded, '\n')
	randomBytes := make([]byte, 8)
	if _, err := rand.Read(randomBytes); err != nil {
		return errors.New("allocate private hand-off receipt staging name")
	}
	temporaryPath := path.Join(ReceiptDirectory, ".receipt-"+hex.EncodeToString(randomBytes)+".tmp")
	file, err := root.OpenFile(temporaryPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("create private hand-off receipt staging file: %w", err)
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		_ = root.Remove(temporaryPath)
		return fmt.Errorf("protect private hand-off receipt staging file: %w", err)
	}
	_, writeErr := file.Write(encoded)
	syncErr := file.Sync()
	closeErr := file.Close()
	if writeErr != nil || syncErr != nil || closeErr != nil {
		_ = root.Remove(temporaryPath)
		return fmt.Errorf("write private hand-off receipt: %w", errors.Join(writeErr, syncErr, closeErr))
	}
	finalPath := receiptPath(receipt.ReceiptID)
	if err := root.Rename(temporaryPath, finalPath); err != nil {
		_ = root.Remove(temporaryPath)
		return fmt.Errorf("publish private hand-off receipt: %w", err)
	}
	return syncRootDirectory(root, ReceiptDirectory)
}

// readReceipt strictly decodes one protected regular journal without returning
// its private fields in an error.
func readReceipt(ctx context.Context, root *os.Root, receiptID string) (privateReceipt, error) {
	filePath := receiptPath(receiptID)
	info, err := root.Lstat(filePath)
	if err != nil {
		return privateReceipt{}, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() <= 0 || info.Size() > maximumReceiptBytes {
		return privateReceipt{}, errors.New("private hand-off receipt is not a protected bounded regular file")
	}
	file, err := root.Open(filePath)
	if err != nil {
		return privateReceipt{}, errors.New("open private hand-off receipt")
	}
	data, readErr := io.ReadAll(io.LimitReader(contextReader{context: ctx, reader: file}, maximumReceiptBytes+1))
	closeErr := file.Close()
	if readErr != nil || closeErr != nil || int64(len(data)) > maximumReceiptBytes {
		return privateReceipt{}, errors.New("read private hand-off receipt")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var receipt privateReceipt
	if err := decoder.Decode(&receipt); err != nil {
		return privateReceipt{}, errors.New("decode private hand-off receipt")
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return privateReceipt{}, errors.New("private hand-off receipt contains trailing JSON")
	}
	if err := validateReceipt(receipt, receiptID); err != nil {
		return privateReceipt{}, err
	}
	return receipt, nil
}

// validateReceipt checks only closed enums, digests, and compiled relative paths.
func validateReceipt(receipt privateReceipt, expectedID string) error {
	if receipt.SchemaVersion != receiptSchemaVersion || receipt.Kind != receiptKind || receipt.ReceiptID != expectedID || receipt.PlanSHA256 != expectedID {
		return errors.New("private hand-off receipt identity is invalid")
	}
	if !validLowerHexDigest(receipt.HandoffID) || !validLowerHexDigest(receipt.ReceiptID) {
		return errors.New("private hand-off receipt digest is invalid")
	}
	if !filepath.IsAbs(receipt.TargetRoot) || filepath.Clean(receipt.TargetRoot) != receipt.TargetRoot || strings.IndexFunc(receipt.TargetRoot, unicode.IsControl) >= 0 {
		return errors.New("private hand-off receipt target root is invalid")
	}
	switch receipt.State {
	case receiptPrepared, receiptApplying, receiptCommitted, receiptRollingBack, receiptRolledBack:
	default:
		return errors.New("private hand-off receipt state is invalid")
	}
	if len(receipt.Actions) == 0 || len(receipt.Actions) > len(handoffReceiptActionPolicies()) {
		return errors.New("private hand-off receipt action set is invalid")
	}
	policies := handoffReceiptActionPolicies()
	seen := make(map[string]bool, len(receipt.Actions))
	for index, action := range receipt.Actions {
		if action.ID == "" || validateCompiledPath(action.Path) != nil {
			return errors.New("private hand-off receipt action is invalid")
		}
		policy, found := policies[action.ID]
		if !found || seen[action.ID] || !policy.accepts(action) {
			return errors.New("private hand-off receipt action is outside compiled policy")
		}
		seen[action.ID] = true
		if action.BackupPath != "" && validateCompiledPath(action.BackupPath) != nil {
			return errors.New("private hand-off receipt backup path is invalid")
		}
		if action.StagePath != "" && validateCompiledPath(action.StagePath) != nil {
			return errors.New("private hand-off receipt staging path is invalid")
		}
		switch action.OriginalKind {
		case originalAbsent:
			if action.OriginalMode != 0 || action.OriginalSHA256 != "" || action.OriginalSize != 0 || action.OriginalLinkTarget != "" {
				return errors.New("private hand-off receipt absent-original metadata is invalid")
			}
		case originalFile:
			if action.OriginalMode > 0o777 || !validLowerHexDigest(action.OriginalSHA256) || action.OriginalSize < 0 || action.OriginalSize > maximumBackupBytes || action.OriginalLinkTarget != "" {
				return errors.New("private hand-off receipt original-file metadata is invalid")
			}
		case originalSymlink:
			if action.OriginalMode != 0 || action.OriginalSHA256 != "" || action.OriginalSize != 0 || action.OriginalLinkTarget == "" || len(action.OriginalLinkTarget) > 4096 || strings.ContainsRune(action.OriginalLinkTarget, '\x00') {
				return errors.New("private hand-off receipt original-link metadata is invalid")
			}
		default:
			return errors.New("private hand-off receipt original kind is invalid")
		}
		expectedStage, expectedBackup := transactionSiblingPaths(action.Path, receipt.PlanSHA256, index)
		if !action.Required {
			if action.StagePath != "" || action.BackupPath != "" || action.Applied || action.BackupCreated {
				return errors.New("private hand-off receipt unchanged action state is invalid")
			}
			continue
		}
		if action.DesiredKind == ChangeAbsent {
			expectedStage = ""
		}
		if action.OriginalKind == originalAbsent {
			expectedBackup = ""
		}
		if action.StagePath != expectedStage || action.BackupPath != expectedBackup {
			return errors.New("private hand-off receipt transaction paths are invalid")
		}
		if action.BackupCreated && action.OriginalKind == originalAbsent {
			return errors.New("private hand-off receipt backup state is invalid")
		}
	}
	if err := validateReceiptFeatureSets(seen, receipt.Actions); err != nil {
		return err
	}
	if err := validateReceiptDirectories(receipt.CreatedDirectories, receipt.Actions); err != nil {
		return err
	}
	return nil
}

// receiptActionPolicy is the complete non-private destination authority for one action.
type receiptActionPolicy struct {
	// paths contains the only destination alternatives accepted for the action.
	paths map[string]bool
	// kind is the only desired filesystem object kind.
	kind ChangeKind
	// mode is the only accepted regular-file mode.
	mode uint32
	// linkTarget is the only accepted desired symbolic-link target.
	linkTarget string
}

// accepts reports whether receipt metadata stays within one compiled policy.
func (policy receiptActionPolicy) accepts(action receiptAction) bool {
	if !policy.paths[action.Path] || action.DesiredKind != policy.kind || action.DesiredMode != policy.mode || action.DesiredLinkTarget != policy.linkTarget {
		return false
	}
	if action.DesiredKind == ChangeFile {
		return validLowerHexDigest(action.DesiredSHA256) && action.DesiredSize >= 0
	}
	return action.DesiredSHA256 == "" && action.DesiredSize == 0
}

// handoffReceiptActionPolicies returns a newly allocated closed action policy.
func handoffReceiptActionPolicies() map[string]receiptActionPolicy {
	policies := make(map[string]receiptActionPolicy, 17)
	for _, firmware := range handoff.FirmwarePolicies() {
		paths := map[string]bool{firmware.Destination: true}
		if firmware.ID == "adsp-dtb" {
			paths[DisabledADSPPath] = true
		}
		policies["firmware-"+firmware.ID] = receiptActionPolicy{paths: paths, kind: ChangeFile, mode: 0o644}
	}
	policies["firmware-adsp-inactive-path"] = receiptActionPolicy{
		paths: map[string]bool{ActiveADSPPath: true, DisabledADSPPath: true}, kind: ChangeAbsent,
	}
	policies["firmware-denali-gpu-link"] = receiptActionPolicy{
		paths: map[string]bool{DenaliGPULinkPath: true}, kind: ChangeSymlink, linkTarget: denaliGPULinkTarget,
	}
	policies["bluetooth-private-config"] = receiptActionPolicy{
		paths: map[string]bool{BluetoothConfigPath: true}, kind: ChangeFile, mode: 0o600,
	}
	policies["bluetooth-linux-armer-binary"] = receiptActionPolicy{
		paths: map[string]bool{InstalledBinaryPath: true}, kind: ChangeFile, mode: 0o755,
	}
	policies["bluetooth-systemd-unit"] = receiptActionPolicy{
		paths: map[string]bool{BluetoothUnitPath: true}, kind: ChangeFile, mode: 0o644,
	}
	policies["bluetooth-systemd-wants-link"] = receiptActionPolicy{
		paths: map[string]bool{BluetoothWantsPath: true}, kind: ChangeSymlink, linkTarget: bluetoothWantsTarget,
	}
	return policies
}

// validateReceiptFeatureSets requires either a complete firmware group, a
// complete Bluetooth group, or both, with complementary aDSP destinations.
func validateReceiptFeatureSets(seen map[string]bool, actions []receiptAction) error {
	firmwareCount := 0
	for identifier := range seen {
		if strings.HasPrefix(identifier, "firmware-") {
			firmwareCount++
		}
	}
	if firmwareCount != 0 && firmwareCount != len(handoff.FirmwarePolicies())+2 {
		return errors.New("private hand-off receipt firmware action set is incomplete")
	}
	if firmwareCount != 0 {
		byID := make(map[string]receiptAction, len(actions))
		for _, action := range actions {
			byID[action.ID] = action
		}
		adsp, adspFound := byID["firmware-adsp-dtb"]
		inactive, inactiveFound := byID["firmware-adsp-inactive-path"]
		complementary := (adsp.Path == ActiveADSPPath && inactive.Path == DisabledADSPPath) ||
			(adsp.Path == DisabledADSPPath && inactive.Path == ActiveADSPPath)
		if !adspFound || !inactiveFound || !complementary {
			return errors.New("private hand-off receipt aDSP policy is incomplete")
		}
	}
	bluetoothIDs := []string{"bluetooth-private-config", "bluetooth-linux-armer-binary", "bluetooth-systemd-unit", "bluetooth-systemd-wants-link"}
	bluetoothCount := 0
	for _, identifier := range bluetoothIDs {
		if seen[identifier] {
			bluetoothCount++
		}
	}
	if bluetoothCount != 0 && bluetoothCount != len(bluetoothIDs) {
		return errors.New("private hand-off receipt Bluetooth action set is incomplete")
	}
	expectedOrder := make([]string, 0, len(actions))
	if firmwareCount != 0 {
		for _, firmware := range handoff.FirmwarePolicies() {
			expectedOrder = append(expectedOrder, "firmware-"+firmware.ID)
		}
		expectedOrder = append(expectedOrder, "firmware-adsp-inactive-path", "firmware-denali-gpu-link")
	}
	if bluetoothCount != 0 {
		expectedOrder = append(expectedOrder, bluetoothIDs...)
	}
	if len(expectedOrder) != len(actions) {
		return errors.New("private hand-off receipt action order is invalid")
	}
	for index, action := range actions {
		if action.ID != expectedOrder[index] {
			return errors.New("private hand-off receipt action order is invalid")
		}
	}
	return nil
}

// validateReceiptDirectories limits rollback clean-up to canonical ancestors of
// compiled action paths in deterministic shallowest-first order.
func validateReceiptDirectories(directories []string, actions []receiptAction) error {
	seen := make(map[string]bool, len(directories))
	previousDepth := -1
	previous := ""
	for _, directory := range directories {
		if validateCompiledPath(directory) != nil || seen[directory] {
			return errors.New("private hand-off receipt created-directory set is invalid")
		}
		accepted := false
		for _, action := range actions {
			if strings.HasPrefix(action.Path, directory+"/") {
				accepted = true
				break
			}
		}
		if !accepted {
			return errors.New("private hand-off receipt created directory is outside compiled policy")
		}
		depth := strings.Count(directory, "/")
		if depth < previousDepth || (depth == previousDepth && previous > directory) {
			return errors.New("private hand-off receipt created directories are not canonical")
		}
		seen[directory] = true
		previousDepth = depth
		previous = directory
	}
	return nil
}

// validLowerHexDigest validates one canonical SHA-256 representation.
func validLowerHexDigest(value string) bool {
	if len(value) != sha256.Size*2 || strings.ToLower(value) != value {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size
}

// syncRootDirectory flushes descriptor-confined directory metadata.
func syncRootDirectory(root *os.Root, relativePath string) error {
	directory, err := root.Open(relativePath)
	if err != nil {
		return fmt.Errorf("open target directory for synchronisation: %w", err)
	}
	syncErr := directory.Sync()
	closeErr := directory.Close()
	if syncErr != nil || closeErr != nil {
		return fmt.Errorf("synchronise target directory: %w", errors.Join(syncErr, closeErr))
	}
	return nil
}
