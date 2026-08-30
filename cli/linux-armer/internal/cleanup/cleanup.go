// Package cleanup implements the reversible removal of obsolete SP11
// workarounds.
package cleanup

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Rule describes one retired workaround that can be recognised safely at a
// fixed path below the selected system root.
type Rule struct {
	// ID is the stable identifier written to plans and receipts.
	ID string
	// Feature groups the rule by the hardware capability it once supported.
	Feature string
	// Path is a relative, pre-audited path below the selected system root.
	Path string
	// Reason explains why the workaround is no longer appropriate.
	Reason string
	// Markers are strings that must all occur before a regular file is
	// recognised as the known workaround.
	Markers []string
	// SymlinkTarget is the one root-relative destination permitted when the
	// rule path is a symbolic link. An empty value makes every symbolic link at
	// the path a manual-review finding.
	SymlinkTarget string
}

// LegacyRules is the allow-list of obsolete workarounds that clean-up may
// inspect. Apply never removes paths that are absent from this list.
var LegacyRules = []Rule{
	{ID: "audio-wsa-unit", Feature: "audio", Path: "etc/systemd/system/sp11-wsa-routing.service", Reason: "legacy WSA routing is superseded by the native FullIO topology and UCM", Markers: []string{"sp11-enable-wsa-routing"}},
	{ID: "audio-wsa-enablement", Feature: "audio", Path: "etc/systemd/system/multi-user.target.wants/sp11-wsa-routing.service", Reason: "legacy WSA routing enablement is obsolete", SymlinkTarget: "etc/systemd/system/sp11-wsa-routing.service"},
	{ID: "audio-wsa-helper", Feature: "audio", Path: "usr/local/sbin/sp11-enable-wsa-routing.sh", Reason: "legacy WSA routing is superseded", Markers: []string{"sp11-wsa-routing"}},
	{ID: "audio-wsa-helper-old", Feature: "audio", Path: "usr/local/sbin/sp11-enable-wsa-routing", Reason: "legacy WSA routing is superseded", Markers: []string{"sp11"}},
	{ID: "audio-manual-sink", Feature: "audio", Path: "etc/pipewire/pipewire.conf.d/50-sp11-speakers.conf", Reason: "manual PipeWire sinks conflict with current native audio routing", Markers: []string{"sp11"}},
	{ID: "audio-boot-race-helper", Feature: "audio", Path: "usr/local/sbin/sp11-fix-audio-boot-race", Reason: "legacy boot-race restarts are obsolete", Markers: []string{"sp11-wsa-routing"}},
	{ID: "touch-modprobe", Feature: "touchscreen", Path: "etc/modprobe.d/sp11-touchscreen.conf", Reason: "the current kernel contains the touchscreen driver in-tree", Markers: []string{"mshw0485_touch"}},
	{ID: "touch-modules-load", Feature: "touchscreen", Path: "etc/modules-load.d/sp11-touchscreen.conf", Reason: "the current kernel contains the touchscreen driver in-tree", Markers: []string{"mshw0485_touch"}},
	{ID: "touch-initramfs-hook", Feature: "touchscreen", Path: "etc/initramfs-tools/hooks/sp11-touchscreen", Reason: "the current kernel contains the touchscreen driver in-tree", Markers: []string{"mshw0485_touch"}},
	{ID: "touch-dracut", Feature: "touchscreen", Path: "etc/dracut.conf.d/91-sp11-touchscreen.conf", Reason: "the current kernel contains the touchscreen driver in-tree", Markers: []string{"mshw0485_touch"}},
	{ID: "pen-g6-unit", Feature: "pen", Path: "etc/systemd/system/g6-pen.service", Reason: "production stylus input now uses the paired iptsd integration", Markers: []string{"g6-pen"}},
	{ID: "pen-g6-enablement", Feature: "pen", Path: "etc/systemd/system/multi-user.target.wants/g6-pen.service", Reason: "production stylus input now uses the paired iptsd integration", SymlinkTarget: "etc/systemd/system/g6-pen.service"},
}

// Finding records the current state of one path matching a clean-up rule.
type Finding struct {
	// Rule is the allow-listed clean-up rule that selected the path.
	Rule Rule `json:"rule"`
	// Path is the absolute target below ScanReport.Root.
	Path string `json:"path"`
	// SHA256 identifies regular-file content at scan time.
	SHA256 string `json:"sha256,omitempty"`
	// Kind describes whether the target is a regular file, symlink, or another
	// filesystem object.
	Kind string `json:"kind"`
	// SymlinkTarget records the unmodified link text used during revalidation.
	SymlinkTarget string `json:"symlink_target,omitempty"`
	// Recognized is true only when the object is safe for automated removal.
	Recognized bool `json:"recognized"`
	// Details explains the finding and any reason manual review is required.
	Details string `json:"details"`
}

// ScanReport is a point-in-time clean-up plan for one resolved system root.
type ScanReport struct {
	// Root is the absolute, symlink-resolved boundary for every finding.
	Root string `json:"root"`
	// Findings contains allow-listed paths that currently exist.
	Findings []Finding `json:"findings"`
}

// Receipt describes the backup and removals completed by Apply.
type Receipt struct {
	// State is prepared before removal and complete after every target is removed.
	State string `json:"state"`
	// CreatedAt records when the clean-up transaction was performed.
	CreatedAt time.Time `json:"created_at"`
	// Root is the system root against which the plan was applied.
	Root string `json:"root"`
	// Backup is the private directory holding copies of removed entries.
	Backup string `json:"backup"`
	// Changes maps each removed target to its recoverable backup.
	Changes []ReceiptItem `json:"changes"`
}

// applyOperations isolates the one destructive filesystem operation so tests
// can prove the recovery receipt exists before removal begins.
type applyOperations struct {
	rename func(string, string) error
	remove func(string) error
}

// ReceiptItem maps one removed workaround to its backup copy.
type ReceiptItem struct {
	// RuleID identifies the allow-listed rule that authorised the removal.
	RuleID string `json:"rule_id"`
	// Original is the removed absolute path.
	Original string `json:"original"`
	// BackupPath is the path from which the original can be restored.
	BackupPath string `json:"backup_path"`
	// QuarantinePath is the same-filesystem temporary location used while the
	// exact removed entry is copied into its durable backup.
	QuarantinePath string `json:"quarantine_path,omitempty"`
	// Kind records whether the recoverable entry is a regular file or symbolic
	// link.
	Kind string `json:"kind"`
	// SHA256 records regular-file content for later integrity checks.
	SHA256 string `json:"sha256,omitempty"`
	// SymlinkTarget records exact link text for later integrity checks.
	SymlinkTarget string `json:"symlink_target,omitempty"`
}

// RestoreReport records entries restored from a clean-up receipt and entries
// that were already present with exactly the reviewed contents.
type RestoreReport struct {
	// Root is the resolved target root restored by the operation.
	Root string `json:"root"`
	// Receipt is the recovery receipt supplied by the operator.
	Receipt string `json:"receipt"`
	// Restored lists original paths recreated from a verified recovery copy.
	Restored []string `json:"restored"`
	// AlreadyPresent lists paths already matching their receipt entry.
	AlreadyPresent []string `json:"already_present,omitempty"`
}

// Scan inspects the allow-listed legacy paths below root without changing the
// filesystem. Content that does not match a rule's markers is reported for
// manual review and cannot be removed automatically.
func Scan(root string) (ScanReport, error) {
	resolved, err := ResolveRoot(root)
	if err != nil {
		return ScanReport{}, err
	}
	report := ScanReport{Root: resolved}
	for _, rule := range LegacyRules {
		path, err := safeJoin(resolved, rule.Path)
		if err != nil {
			return ScanReport{}, err
		}
		info, err := os.Lstat(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return ScanReport{}, err
		}
		finding := Finding{Rule: rule, Path: path, Details: rule.Reason}
		if info.Mode()&os.ModeSymlink != 0 {
			finding.Kind = "symlink"
			target, readErr := os.Readlink(path)
			if readErr != nil {
				return ScanReport{}, readErr
			}
			finding.SymlinkTarget = target
			finding.Details += "; target=" + target
			if rule.SymlinkTarget == "" {
				finding.Details = "path is a symbolic link, but this rule permits only a regular file; manual review required"
			} else {
				observedTarget, resolveErr := resolveSymlinkTarget(resolved, path, target)
				expectedTarget, expectedErr := safeJoin(resolved, rule.SymlinkTarget)
				if resolveErr == nil && expectedErr == nil && observedTarget == expectedTarget {
					finding.Recognized = true
				} else {
					finding.Details = "symbolic-link target does not match the known workaround; manual review required"
				}
			}
		} else if info.Mode().IsRegular() {
			finding.Kind = "file"
			data, readErr := os.ReadFile(path)
			if readErr != nil {
				return ScanReport{}, readErr
			}
			digest := sha256.Sum256(data)
			finding.SHA256 = hex.EncodeToString(digest[:])
			if len(rule.Markers) == 0 {
				finding.Details = "path is a regular file, but this rule permits only a symbolic link; manual review required"
			} else {
				finding.Recognized = true
				for _, marker := range rule.Markers {
					if !strings.Contains(string(data), marker) {
						finding.Recognized = false
						finding.Details = "path matches a legacy workaround, but a content marker is absent; manual review required"
						break
					}
				}
			}
		} else {
			finding.Kind = info.Mode().Type().String()
			finding.Recognized = false
			finding.Details = "path is not a regular file or symlink; manual review required"
		}
		report.Findings = append(report.Findings, finding)
	}
	sort.Slice(report.Findings, func(i, j int) bool { return report.Findings[i].Rule.ID < report.Findings[j].Rule.ID })
	return report, nil
}

// ResolveRoot returns the absolute, symlink-resolved directory that bounds a
// scan or reviewed plan.
func ResolveRoot(root string) (string, error) {
	absolute, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return "", fmt.Errorf("resolve cleanup root: %w", err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", fmt.Errorf("inspect cleanup root: %w", err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("cleanup root is not a directory: %s", resolved)
	}
	return resolved, nil
}

// ReadScanReport decodes exactly one strict JSON plan. Apply still revalidates
// every planned finding against the current filesystem before mutation.
func ReadScanReport(reader io.Reader) (ScanReport, error) {
	decoder := json.NewDecoder(reader)
	decoder.DisallowUnknownFields()
	var report ScanReport
	if err := decoder.Decode(&report); err != nil {
		return ScanReport{}, fmt.Errorf("decode cleanup plan: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return ScanReport{}, errors.New("decode cleanup plan: multiple JSON values are not allowed")
		}
		return ScanReport{}, fmt.Errorf("decode cleanup plan trailing content: %w", err)
	}
	if strings.TrimSpace(report.Root) == "" {
		return ScanReport{}, errors.New("decode cleanup plan: root is required")
	}
	return report, nil
}

// ReadReceipt decodes exactly one strict clean-up receipt for recovery.
func ReadReceipt(reader io.Reader) (Receipt, error) {
	decoder := json.NewDecoder(reader)
	decoder.DisallowUnknownFields()
	var receipt Receipt
	if err := decoder.Decode(&receipt); err != nil {
		return Receipt{}, fmt.Errorf("decode cleanup receipt: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return Receipt{}, errors.New("decode cleanup receipt: multiple JSON values are not allowed")
		}
		return Receipt{}, fmt.Errorf("decode cleanup receipt trailing content: %w", err)
	}
	return receipt, nil
}

// Restore verifies a prepared or completed receipt and recreates missing
// originals from exact backups without overwriting changed local content.
func Restore(receipt Receipt, receiptPath string, yes bool) (RestoreReport, error) {
	report := RestoreReport{Root: receipt.Root, Receipt: receiptPath}
	if !yes {
		return report, errors.New("cleanup restore requires --yes after reviewing the receipt")
	}
	if err := validateReceipt(receipt); err != nil {
		return report, err
	}
	for _, change := range receipt.Changes {
		if _, err := os.Lstat(change.Original); err == nil {
			if verifyReceiptEntry(change.Original, change) != nil {
				return report, fmt.Errorf("refuse to overwrite changed restoration target %s", change.Original)
			}
			report.AlreadyPresent = append(report.AlreadyPresent, change.Original)
			continue
		} else if !errors.Is(err, os.ErrNotExist) {
			return report, fmt.Errorf("inspect restoration target %s: %w", change.Original, err)
		}
		source := change.BackupPath
		if _, err := os.Lstat(source); errors.Is(err, os.ErrNotExist) && change.QuarantinePath != "" {
			source = change.QuarantinePath
		} else if err != nil {
			return report, fmt.Errorf("inspect recovery copy %s: %w", source, err)
		}
		if _, err := os.Lstat(source); err != nil {
			return report, fmt.Errorf("no recovery copy remains for %s: %w", change.Original, err)
		}
		if err := ensureResolvedParentWithin(receipt.Root, source); err != nil {
			return report, fmt.Errorf("validate recovery copy %s: %w", source, err)
		}
		if err := verifyReceiptEntry(source, change); err != nil {
			return report, fmt.Errorf("verify recovery copy for %s: %w", change.Original, err)
		}
		if err := restoreEntry(receipt.Root, source, change); err != nil {
			return report, err
		}
		report.Restored = append(report.Restored, change.Original)
	}
	return report, nil
}

// validateReceipt confines every recovery path to the selected root and exact
// compiled rule before Restore reads or writes any entry.
func validateReceipt(receipt Receipt) error {
	if receipt.State != "prepared" && receipt.State != "complete" {
		return fmt.Errorf("cleanup receipt has invalid state %q", receipt.State)
	}
	resolvedRoot, err := ResolveRoot(receipt.Root)
	if err != nil {
		return err
	}
	if resolvedRoot != receipt.Root {
		return fmt.Errorf("cleanup receipt root is not canonical: %s", receipt.Root)
	}
	backupParent, err := safeJoin(receipt.Root, "var/lib/linux-armer/backups")
	if err != nil {
		return err
	}
	if filepath.Dir(filepath.Clean(receipt.Backup)) != backupParent {
		return fmt.Errorf("cleanup receipt backup is outside the standard backup directory: %s", receipt.Backup)
	}
	rulesByID := make(map[string]Rule, len(LegacyRules))
	for _, rule := range LegacyRules {
		rulesByID[rule.ID] = rule
	}
	seen := make(map[string]bool, len(receipt.Changes))
	for _, change := range receipt.Changes {
		rule, ok := rulesByID[change.RuleID]
		if !ok || seen[change.RuleID] {
			return fmt.Errorf("cleanup receipt contains an unknown or duplicate rule %q", change.RuleID)
		}
		seen[change.RuleID] = true
		expectedOriginal, err := safeJoin(receipt.Root, rule.Path)
		if err != nil {
			return err
		}
		if filepath.Clean(change.Original) != expectedOriginal {
			return fmt.Errorf("cleanup receipt original changed for rule %s", change.RuleID)
		}
		relative, err := filepath.Rel(receipt.Root, expectedOriginal)
		if err != nil {
			return err
		}
		expectedBackup := filepath.Join(receipt.Backup, relative)
		if filepath.Clean(change.BackupPath) != expectedBackup {
			return fmt.Errorf("cleanup receipt backup changed for rule %s", change.RuleID)
		}
		if err := validateQuarantinePath(change); err != nil {
			return err
		}
		switch change.Kind {
		case "file":
			digest, err := hex.DecodeString(change.SHA256)
			if err != nil || len(digest) != sha256.Size {
				return fmt.Errorf("cleanup receipt has invalid SHA-256 for rule %s", change.RuleID)
			}
		case "symlink":
			if change.SymlinkTarget == "" {
				return fmt.Errorf("cleanup receipt has no symbolic-link target for rule %s", change.RuleID)
			}
		default:
			return fmt.Errorf("cleanup receipt has unsupported kind %q for rule %s", change.Kind, change.RuleID)
		}
	}
	return nil
}

// validateQuarantinePath checks the optional same-directory recovery location
// generated by Apply without requiring it still to exist.
func validateQuarantinePath(change ReceiptItem) error {
	if change.QuarantinePath == "" {
		return nil
	}
	quarantineDirectory := filepath.Dir(filepath.Clean(change.QuarantinePath))
	if filepath.Dir(quarantineDirectory) != filepath.Dir(change.Original) ||
		filepath.Base(change.QuarantinePath) != filepath.Base(change.Original) {
		return fmt.Errorf("cleanup receipt has invalid quarantine path for rule %s", change.RuleID)
	}
	directoryName := filepath.Base(quarantineDirectory)
	if !strings.HasPrefix(directoryName, ".linux-armer-cleanup-") ||
		!strings.HasSuffix(directoryName, "-"+change.RuleID) {
		return fmt.Errorf("cleanup receipt has unexpected quarantine directory for rule %s", change.RuleID)
	}
	return nil
}

// ensureResolvedParentWithin rejects recovery sources whose parent directory
// resolves outside the receipt's target root.
func ensureResolvedParentWithin(root, path string) error {
	resolvedParent, err := filepath.EvalSymlinks(filepath.Dir(path))
	if err != nil {
		return err
	}
	if !withinRoot(root, resolvedParent) {
		return fmt.Errorf("resolved parent escapes root: %s", resolvedParent)
	}
	return nil
}

// verifyReceiptEntry compares one current or recovery entry with the digest or
// symbolic-link text recorded in its receipt.
func verifyReceiptEntry(path string, change ReceiptItem) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	switch change.Kind {
	case "file":
		if !info.Mode().IsRegular() {
			return fmt.Errorf("object is not a regular file")
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		digest := sha256.Sum256(data)
		if got := hex.EncodeToString(digest[:]); got != change.SHA256 {
			return fmt.Errorf("SHA-256 is %s, want %s", got, change.SHA256)
		}
	case "symlink":
		if info.Mode()&os.ModeSymlink == 0 {
			return fmt.Errorf("object is not a symbolic link")
		}
		target, err := os.Readlink(path)
		if err != nil {
			return err
		}
		if target != change.SymlinkTarget {
			return fmt.Errorf("symbolic-link target is %q, want %q", target, change.SymlinkTarget)
		}
	default:
		return fmt.Errorf("unsupported recovery kind %q", change.Kind)
	}
	return nil
}

// restoreEntry recreates one missing original without overwriting a concurrent
// replacement and preserves the verified recovery copy for later auditing.
func restoreEntry(root, source string, change ReceiptItem) error {
	if err := ensureResolvedParentWithin(root, change.Original); err != nil {
		return fmt.Errorf("validate restoration target %s: %w", change.Original, err)
	}
	parent := filepath.Dir(change.Original)
	if change.Kind == "symlink" {
		target, err := os.Readlink(source)
		if err != nil {
			return fmt.Errorf("read recovery symbolic link for %s: %w", change.Original, err)
		}
		if err := os.Symlink(target, change.Original); err != nil {
			return fmt.Errorf("restore %s without overwrite: %w", change.Original, err)
		}
		return syncDirectory(parent)
	}
	temporaryDirectory := filepath.Join(parent, ".linux-armer-restore-"+time.Now().UTC().Format("20060102T150405.000000000Z")+"-"+change.RuleID)
	if err := os.Mkdir(temporaryDirectory, 0o700); err != nil {
		return fmt.Errorf("create restoration workspace for %s: %w", change.Original, err)
	}
	if err := syncDirectory(parent); err != nil {
		return fmt.Errorf("persist restoration workspace for %s: %w", change.Original, err)
	}
	temporaryPath := filepath.Join(temporaryDirectory, filepath.Base(change.Original))
	if err := copyEntry(source, temporaryPath); err != nil {
		return fmt.Errorf("prepare restoration of %s: %w", change.Original, err)
	}
	if err := syncDirectory(temporaryDirectory); err != nil {
		return fmt.Errorf("persist prepared restoration of %s: %w", change.Original, err)
	}
	if err := os.Link(temporaryPath, change.Original); err != nil {
		return fmt.Errorf("restore %s without overwrite: %w", change.Original, err)
	}
	if err := syncDirectory(parent); err != nil {
		return fmt.Errorf("persist restoration of %s: %w", change.Original, err)
	}
	removeFileErr := os.Remove(temporaryPath)
	removeDirectoryErr := os.Remove(temporaryDirectory)
	syncErr := syncDirectory(parent)
	if err := errors.Join(removeFileErr, removeDirectoryErr, syncErr); err != nil {
		return fmt.Errorf("remove restoration workspace for %s: %w", change.Original, err)
	}
	return nil
}

// Apply backs up and removes recognised findings. Unrecognised content is
// never removed.
func Apply(report ScanReport, yes bool) (Receipt, error) {
	return apply(report, yes, applyOperations{rename: os.Rename, remove: os.Remove})
}

// apply performs the clean-up transaction with an injectable removal boundary.
func apply(report ScanReport, yes bool, operations applyOperations) (Receipt, error) {
	if !yes {
		return Receipt{}, errors.New("cleanup apply requires --yes after reviewing clean plan")
	}
	if operations.rename == nil || operations.remove == nil {
		return Receipt{}, errors.New("cleanup filesystem operations are unavailable")
	}
	validatedFindings, err := revalidateFindings(report)
	if err != nil {
		return Receipt{}, err
	}
	recognised := make([]Finding, 0, len(validatedFindings))
	for _, finding := range validatedFindings {
		if finding.Recognized {
			recognised = append(recognised, finding)
		}
	}
	if len(recognised) == 0 {
		return Receipt{State: "complete", CreatedAt: time.Now().UTC(), Root: report.Root}, nil
	}
	stamp := time.Now().UTC().Format("20060102T150405.000000000Z")
	backupParent, err := safeJoin(report.Root, "var/lib/linux-armer/backups")
	if err != nil {
		return Receipt{}, err
	}
	if err := ensureBackupParent(report.Root, backupParent); err != nil {
		return Receipt{}, fmt.Errorf("create cleanup backup parent: %w", err)
	}
	backup := filepath.Join(backupParent, stamp)
	if err := os.Mkdir(backup, 0o700); err != nil {
		return Receipt{}, fmt.Errorf("create cleanup backup: %w", err)
	}
	if err := syncDirectory(backupParent); err != nil {
		return Receipt{}, fmt.Errorf("persist cleanup backup directory: %w", err)
	}
	receipt := Receipt{State: "prepared", CreatedAt: time.Now().UTC(), Root: report.Root, Backup: backup}
	findingByRule := make(map[string]Finding, len(recognised))
	quarantineDirectories := make([]string, 0, len(recognised))
	for _, finding := range recognised {
		relative, err := filepath.Rel(report.Root, finding.Path)
		if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return Receipt{}, fmt.Errorf("unsafe cleanup path %s", finding.Path)
		}
		backupPath := filepath.Join(backup, relative)
		quarantineDirectory := filepath.Join(filepath.Dir(finding.Path), ".linux-armer-cleanup-"+stamp+"-"+finding.Rule.ID)
		if !withinRoot(report.Root, quarantineDirectory) {
			return Receipt{}, fmt.Errorf("unsafe cleanup quarantine path %s", quarantineDirectory)
		}
		if err := os.Mkdir(quarantineDirectory, 0o700); err != nil {
			removeEmptyDirectories(quarantineDirectories)
			return Receipt{}, fmt.Errorf("create cleanup quarantine beside %s: %w", finding.Path, err)
		}
		if err := syncDirectory(filepath.Dir(quarantineDirectory)); err != nil {
			quarantineDirectories = append(quarantineDirectories, quarantineDirectory)
			removeEmptyDirectories(quarantineDirectories)
			return Receipt{}, fmt.Errorf("persist cleanup quarantine beside %s: %w", finding.Path, err)
		}
		quarantineDirectories = append(quarantineDirectories, quarantineDirectory)
		quarantinePath := filepath.Join(quarantineDirectory, filepath.Base(finding.Path))
		receipt.Changes = append(receipt.Changes, ReceiptItem{
			RuleID: finding.Rule.ID, Original: finding.Path, BackupPath: backupPath,
			QuarantinePath: quarantinePath, Kind: finding.Kind, SHA256: finding.SHA256,
			SymlinkTarget: finding.SymlinkTarget,
		})
		findingByRule[finding.Rule.ID] = finding
	}
	pendingReceiptPath := filepath.Join(backup, "receipt.pending.json")
	if err := writeJSON(pendingReceiptPath, receipt); err != nil {
		removeEmptyDirectories(quarantineDirectories)
		return Receipt{}, fmt.Errorf("write cleanup recovery receipt before removal: %w", err)
	}
	if err := syncDirectory(backup); err != nil {
		return Receipt{}, fmt.Errorf("persist cleanup recovery data: %w", err)
	}
	for _, change := range receipt.Changes {
		if err := operations.rename(change.Original, change.QuarantinePath); err != nil {
			return receipt, fmt.Errorf("quarantine %s: %w; recovery map: %s", change.Original, err, pendingReceiptPath)
		}
		if err := syncDirectory(filepath.Dir(change.Original)); err != nil {
			return receipt, fmt.Errorf("persist quarantine of %s: %w; recovery map: %s", change.Original, err, pendingReceiptPath)
		}
		if err := verifyQuarantinedFinding(change.QuarantinePath, findingByRule[change.RuleID]); err != nil {
			return receipt, fmt.Errorf("quarantined entry for %s no longer matches the reviewed plan: %w; inspect %s and %s", change.Original, err, change.QuarantinePath, pendingReceiptPath)
		}
		if err := ensurePrivateDirectories(backup, filepath.Dir(change.BackupPath)); err != nil {
			return receipt, fmt.Errorf("prepare backup for %s: %w; original is quarantined at %s", change.Original, err, change.QuarantinePath)
		}
		if err := copyEntry(change.QuarantinePath, change.BackupPath); err != nil {
			return receipt, fmt.Errorf("back up %s: %w; original is quarantined at %s", change.Original, err, change.QuarantinePath)
		}
		if err := syncDirectory(filepath.Dir(change.BackupPath)); err != nil {
			return receipt, fmt.Errorf("persist backup for %s: %w; original is quarantined at %s", change.Original, err, change.QuarantinePath)
		}
		if err := operations.remove(change.QuarantinePath); err != nil {
			return receipt, fmt.Errorf("remove quarantined copy for %s: %w; recover from %s or %s", change.Original, err, change.BackupPath, change.QuarantinePath)
		}
		quarantineDirectory := filepath.Dir(change.QuarantinePath)
		if err := operations.remove(quarantineDirectory); err != nil {
			return receipt, fmt.Errorf("remove empty cleanup quarantine %s: %w; recovery map: %s", quarantineDirectory, err, pendingReceiptPath)
		}
		if err := syncDirectory(filepath.Dir(quarantineDirectory)); err != nil {
			return receipt, fmt.Errorf("persist removal of cleanup quarantine %s: %w; recovery map: %s", quarantineDirectory, err, pendingReceiptPath)
		}
	}
	receipt.State = "complete"
	receiptPath := filepath.Join(backup, "receipt.json")
	if err := writeJSON(receiptPath, receipt); err != nil {
		return receipt, fmt.Errorf("write completed cleanup receipt: %w; recovery receipt remains at %s", err, pendingReceiptPath)
	}
	if err := syncDirectory(backup); err != nil {
		return receipt, fmt.Errorf("persist completed cleanup receipt: %w; recovery receipt remains at %s", err, pendingReceiptPath)
	}
	if err := os.Remove(pendingReceiptPath); err != nil {
		return receipt, fmt.Errorf("remove superseded recovery receipt %s: %w", pendingReceiptPath, err)
	}
	if err := syncDirectory(backup); err != nil {
		return receipt, fmt.Errorf("persist completed cleanup transaction: %w", err)
	}
	return receipt, nil
}

// WriteJSON writes an indented JSON representation suitable for plans and
// human-readable receipts.
func WriteJSON(w io.Writer, value any) error {
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

// ensureBackupParent creates the standard backup hierarchy without assigning
// private permissions to ordinary system directories such as /var or /var/lib.
// Every new directory entry is flushed through its parent before clean-up can
// proceed.
func ensureBackupParent(root, expected string) error {
	directories := []struct {
		relative string
		mode     os.FileMode
	}{
		{relative: "var", mode: 0o755},
		{relative: "var/lib", mode: 0o755},
		{relative: "var/lib/linux-armer", mode: 0o700},
		{relative: "var/lib/linux-armer/backups", mode: 0o700},
	}
	for _, directory := range directories {
		path, err := safeJoin(root, directory.relative)
		if err != nil {
			return err
		}
		if err := ensureDirectory(path, directory.mode); err != nil {
			return err
		}
	}
	if filepath.Clean(expected) != filepath.Join(root, "var", "lib", "linux-armer", "backups") {
		return fmt.Errorf("unexpected cleanup backup parent %s", expected)
	}
	return nil
}

// ensurePrivateDirectories creates every missing directory from root to path
// with private permissions and rejects symbolic links or non-directories in
// the supposedly private hierarchy.
func ensurePrivateDirectories(root, path string) error {
	if path == root {
		return nil
	}
	if !withinRoot(root, path) {
		return fmt.Errorf("private directory path escapes root: %s", path)
	}
	relative, err := filepath.Rel(root, path)
	if err != nil {
		return err
	}
	current := root
	for _, part := range strings.Split(relative, string(filepath.Separator)) {
		current = filepath.Join(current, part)
		if err := ensureDirectory(current, 0o700); err != nil {
			return err
		}
	}
	return nil
}

// ensureDirectory creates one directory when absent, rejects unsafe existing
// objects, and persists a newly created entry through its parent directory.
func ensureDirectory(path string, mode os.FileMode) error {
	info, err := os.Lstat(path)
	if err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return fmt.Errorf("cleanup directory path is not a real directory: %s", path)
		}
		return nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.Mkdir(path, mode); err != nil {
		return err
	}
	return syncDirectory(filepath.Dir(path))
}

// removeEmptyDirectories removes newly prepared quarantine directories after a
// pre-mutation failure. Failures are intentionally ignored because the empty,
// private directories contain no user data.
func removeEmptyDirectories(paths []string) {
	for index := len(paths) - 1; index >= 0; index-- {
		_ = os.Remove(paths[index])
		_ = syncDirectory(filepath.Dir(paths[index]))
	}
}

// resolveSymlinkTarget interprets a link as it would appear inside the selected
// target root, mapping absolute Linux paths into an alternate root when needed.
func resolveSymlinkTarget(root, linkPath, target string) (string, error) {
	if filepath.IsAbs(target) {
		trimmed := strings.TrimPrefix(filepath.Clean(target), string(filepath.Separator))
		return safeJoin(root, trimmed)
	}
	resolved := filepath.Clean(filepath.Join(filepath.Dir(linkPath), target))
	if !withinRoot(root, resolved) {
		return "", fmt.Errorf("symbolic-link target escapes root: %s", target)
	}
	return resolved, nil
}

// verifyQuarantinedFinding proves that the atomic rename moved the exact file
// contents or symbolic-link text reviewed in the plan before it is copied and
// the quarantine is removed.
func verifyQuarantinedFinding(path string, finding Finding) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	switch finding.Kind {
	case "file":
		if !info.Mode().IsRegular() {
			return fmt.Errorf("object kind is %s, want regular file", info.Mode().Type())
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		digest := sha256.Sum256(data)
		if got := hex.EncodeToString(digest[:]); got != finding.SHA256 {
			return fmt.Errorf("SHA-256 is %s, want %s", got, finding.SHA256)
		}
	case "symlink":
		if info.Mode()&os.ModeSymlink == 0 {
			return fmt.Errorf("object kind is %s, want symbolic link", info.Mode().Type())
		}
		target, err := os.Readlink(path)
		if err != nil {
			return err
		}
		if target != finding.SymlinkTarget {
			return fmt.Errorf("symbolic-link target is %q, want %q", target, finding.SymlinkTarget)
		}
	default:
		return fmt.Errorf("unsupported reviewed object kind %q", finding.Kind)
	}
	return nil
}

// safeJoin confines a relative rule path to root and rejects parent-directory
// symlinks that would escape that boundary.
func safeJoin(root, relative string) (string, error) {
	if filepath.IsAbs(relative) {
		return "", fmt.Errorf("cleanup rule path must be relative: %s", relative)
	}
	clean := filepath.Clean(relative)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("unsafe cleanup rule path: %s", relative)
	}
	joined := filepath.Join(root, clean)
	if !withinRoot(root, joined) || joined == root {
		return "", fmt.Errorf("cleanup path escapes root: %s", relative)
	}
	current := root
	parts := strings.Split(clean, string(filepath.Separator))
	for _, part := range parts[:len(parts)-1] {
		current = filepath.Join(current, part)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			break
		}
		if err != nil {
			return "", fmt.Errorf("inspect cleanup path parent %s: %w", current, err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			resolved, err := filepath.EvalSymlinks(current)
			if err != nil {
				return "", fmt.Errorf("resolve cleanup path parent %s: %w", current, err)
			}
			if !withinRoot(root, resolved) {
				return "", fmt.Errorf("cleanup path parent escapes root: %s", current)
			}
			continue
		}
		if !info.IsDir() {
			return "", fmt.Errorf("cleanup path parent is not a directory: %s", current)
		}
	}
	return joined, nil
}

// withinRoot reports whether path is root itself or one of its descendants,
// using path components rather than string prefixes.
func withinRoot(root, path string) bool {
	relative, err := filepath.Rel(root, path)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

// revalidateFindings rescans every planned target immediately before mutation
// and rejects unknown, duplicate, moved, or changed entries.
func revalidateFindings(report ScanReport) ([]Finding, error) {
	current, err := Scan(report.Root)
	if err != nil {
		return nil, fmt.Errorf("revalidate cleanup plan: %w", err)
	}
	currentByID := make(map[string]Finding, len(current.Findings))
	for _, finding := range current.Findings {
		currentByID[finding.Rule.ID] = finding
	}
	rulesByID := make(map[string]Rule, len(LegacyRules))
	for _, rule := range LegacyRules {
		rulesByID[rule.ID] = rule
	}
	validated := make([]Finding, 0, len(report.Findings))
	seen := make(map[string]bool, len(report.Findings))
	for _, planned := range report.Findings {
		rule, known := rulesByID[planned.Rule.ID]
		if !known || planned.Rule.Path != rule.Path || seen[rule.ID] {
			return nil, fmt.Errorf("cleanup plan contains an unknown or duplicate rule %q", planned.Rule.ID)
		}
		seen[rule.ID] = true
		expectedPath, err := safeJoin(current.Root, rule.Path)
		if err != nil {
			return nil, err
		}
		if filepath.Clean(planned.Path) != expectedPath {
			return nil, fmt.Errorf("cleanup plan path changed for rule %s", rule.ID)
		}
		observed, exists := currentByID[rule.ID]
		if !exists {
			return nil, fmt.Errorf("cleanup target changed after planning: %s no longer exists", planned.Path)
		}
		if planned.Recognized != observed.Recognized || planned.Kind != observed.Kind ||
			planned.SHA256 != observed.SHA256 || planned.SymlinkTarget != observed.SymlinkTarget ||
			planned.Details != observed.Details {
			return nil, fmt.Errorf("cleanup target changed after planning: %s", planned.Path)
		}
		validated = append(validated, observed)
	}
	return validated, nil
}

// copyEntry preserves either a regular file's contents and permissions or a
// symlink's link text without following the symlink.
func copyEntry(source, destination string) error {
	info, err := os.Lstat(source)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(source)
		if err != nil {
			return err
		}
		return os.Symlink(target, destination)
	}
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, info.Mode().Perm())
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, in)
	syncErr := out.Sync()
	closeErr := out.Close()
	return errors.Join(copyErr, syncErr, closeErr)
}

// writeJSON creates a private JSON file exactly once, joining encoding and
// close errors so a partial receipt is never treated as successful.
func writeJSON(path string, value any) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	encodeErr := WriteJSON(file, value)
	syncErr := file.Sync()
	closeErr := file.Close()
	return errors.Join(encodeErr, syncErr, closeErr)
}

// syncDirectory persists directory-entry changes so backed-up files and
// receipts survive an unexpected interruption once Apply starts removing
// targets.
func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	syncErr := directory.Sync()
	closeErr := directory.Close()
	return errors.Join(syncErr, closeErr)
}
