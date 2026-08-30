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
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Rule describes one retired workaround that can be recognised safely at a
// fixed path below the selected system root.
type Rule struct {
	// ID is the stable identifier written to plans and receipts.
	ID string
	// Feature groups the rule by the hardware capability it once supported.
	Feature string
	// Path is a relative, pre-audited path below the selected system root or
	// explicit target user home, according to the compiled rule scope.
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
	// scope selects the fixed system root or explicit target user home without
	// exposing a caller-controlled scope through plans or receipts.
	scope ruleScope
	// prefix is an optional byte sequence required at the start of a recognised
	// regular file, such as the ELF identification bytes of a compiled helper.
	prefix []byte
	// maximumSize narrows the bounded content-read limit for this rule.
	maximumSize int64
	// privateContent prevents a low-entropy private value from being exposed as
	// a brute-forceable digest in a public plan or receipt.
	privateContent bool
	// validateContent applies an exact format check after markers match.
	validateContent func([]byte) bool
}

// ruleScope identifies the compiled base directory for one clean-up rule.
type ruleScope uint8

const (
	// ruleScopeSystem resolves a rule beneath the selected target root.
	ruleScopeSystem ruleScope = iota
	// ruleScopeUser resolves a rule beneath the explicit target-visible user home.
	ruleScopeUser
	// maximumLegacyFileBytes bounds every regular-file recognition read.
	maximumLegacyFileBytes int64 = 8 << 20
	// privateIntegrityKeyBytes is the random HMAC key length retained only in a
	// private transaction backup.
	privateIntegrityKeyBytes = 32
	// privateIntegrityKeyName is the fixed private backup entry used for HMAC
	// verification of low-entropy private content.
	privateIntegrityKeyName = ".private-integrity-key"
)

// LegacyRules is the allow-list of obsolete workarounds that clean-up may
// inspect. Apply never removes paths that are absent from this list.
var LegacyRules = []Rule{
	{ID: "audio-wsa-unit", Feature: "audio", Path: "etc/systemd/system/sp11-wsa-routing.service", Reason: "legacy WSA routing is superseded by the native FullIO topology and UCM", Markers: []string{"sp11-enable-wsa-routing"}},
	{ID: "audio-wsa-enablement", Feature: "audio", Path: "etc/systemd/system/multi-user.target.wants/sp11-wsa-routing.service", Reason: "legacy WSA routing enablement is obsolete", SymlinkTarget: "etc/systemd/system/sp11-wsa-routing.service"},
	{ID: "audio-wsa-helper", Feature: "audio", Path: "usr/local/sbin/sp11-enable-wsa-routing.sh", Reason: "legacy WSA routing is superseded", Markers: []string{"sp11-wsa-routing"}},
	{ID: "audio-wsa-helper-old", Feature: "audio", Path: "usr/local/sbin/sp11-enable-wsa-routing", Reason: "legacy WSA routing is superseded", Markers: []string{"sp11"}},
	{ID: "audio-manual-sink", Feature: "audio", Path: "etc/pipewire/pipewire.conf.d/50-sp11-speakers.conf", Reason: "a manually relocated PipeWire sink conflicts with current native audio routing", Markers: []string{"factory.name", "api.alsa.pcm.sink", "node.name", "alsa_output.sp11_speakers", "channelmix.mix-matrix"}},
	{ID: "audio-boot-race-helper", Feature: "audio", Path: "usr/local/sbin/sp11-fix-audio-boot-race", Reason: "legacy boot-race restarts are obsolete", Markers: []string{"sp11-wsa-routing"}},
	{ID: "audio-pipewire-restart-unit", Feature: "audio", Path: "etc/systemd/user/sp11-pipewire-restart.service", Reason: "a manually relocated user-session restart is superseded by native FullIO discovery", Markers: []string{"sp11-wsa-routing-done", "wireplumber", "pipewire"}},
	{ID: "audio-pipewire-restart-enablement", Feature: "audio", Path: "etc/systemd/user/default.target.wants/sp11-pipewire-restart.service", Reason: "a manually relocated user-session restart enablement is obsolete", SymlinkTarget: "etc/systemd/user/sp11-pipewire-restart.service"},
	{ID: "audio-alsa-restore-mask", Feature: "audio", Path: "etc/systemd/system/alsa-restore.service", Reason: "the retired boot-race workaround masked a distribution ALSA service", SymlinkTarget: "dev/null"},
	{ID: "audio-alsa-state-mask", Feature: "audio", Path: "etc/systemd/system/alsa-state.service", Reason: "the retired boot-race workaround masked a distribution ALSA service", SymlinkTarget: "dev/null"},
	{ID: "audio-user-manual-sink", Feature: "audio", Path: ".config/pipewire/pipewire.conf.d/50-sp11-speakers.conf", Reason: "the per-user manual PipeWire sink conflicts with current native audio routing", Markers: []string{"# Surface Pro 11 manual speaker sink.", "factory.name", "api.alsa.pcm.sink", "node.name", "alsa_output.sp11_speakers", "channelmix.mix-matrix"}, scope: ruleScopeUser},
	{ID: "audio-user-wireplumber-duplicate-output", Feature: "audio", Path: ".config/wireplumber/wireplumber.conf.d/51-sp11-no-duplicate-output.conf", Reason: "the retired per-user WirePlumber suppression can hide native audio outputs", Markers: []string{"# The manual Surface sink owns", "alsa_output.platform-sound.pro-output-1.*", "node.disabled", "true"}, scope: ruleScopeUser},
	{ID: "audio-user-pipewire-restart-unit", Feature: "audio", Path: ".config/systemd/user/sp11-pipewire-restart.service", Reason: "legacy user-session restarts are superseded by native FullIO discovery", Markers: []string{"sp11-wsa-routing-done", "wireplumber", "pipewire"}, scope: ruleScopeUser},
	{ID: "audio-user-pipewire-restart-enablement", Feature: "audio", Path: ".config/systemd/user/default.target.wants/sp11-pipewire-restart.service", Reason: "legacy user-session restart enablement is obsolete", SymlinkTarget: ".config/systemd/user/sp11-pipewire-restart.service", scope: ruleScopeUser},
	{ID: "bluetooth-legacy-config", Feature: "bluetooth", Path: "etc/default/sp11-bluetooth-mac", Reason: "the legacy Bluetooth address configuration conflicts with the native private hand-off integration", Markers: []string{"# Surface Pro 11 Bluetooth MAC address.", "SP11_BLUETOOTH_MAC=", "SP11_BLUETOOTH_HCI="}, maximumSize: 4096, privateContent: true, validateContent: validLegacyBluetoothConfig},
	{ID: "bluetooth-legacy-shell-helper", Feature: "bluetooth", Path: "usr/local/sbin/sp11-bluetooth-mac", Reason: "the legacy shell Bluetooth address helper is superseded by the native hand-off integration", Markers: []string{"CONFIG=\"${CONFIG:-/etc/default/sp11-bluetooth-mac}\"", "Configures a Surface Pro 11 Bluetooth public address with btmgmt.", "sp11-bluetooth-mac@.service"}},
	{ID: "bluetooth-legacy-raw-helper", Feature: "bluetooth", Path: "usr/local/sbin/sp11-bt-set-addr", Reason: "the legacy C Bluetooth address helper is superseded by the native bounded management client", Markers: []string{"set-public-address  status", "hci%u not found after 120s", "Success: public address set", "Error: failed after 60 attempts"}, prefix: []byte{0x7f, 'E', 'L', 'F'}},
	{ID: "bluetooth-legacy-unit", Feature: "bluetooth", Path: "etc/systemd/system/sp11-bluetooth-mac@.service", Reason: "the legacy Bluetooth address unit conflicts with the native hand-off service", Markers: []string{"Description=Set Surface Pro 11 Bluetooth public address on %I", "ConditionPathExists=/etc/default/sp11-bluetooth-mac"}, validateContent: validLegacyBluetoothUnit},
	{ID: "bluetooth-legacy-udev", Feature: "bluetooth", Path: "etc/udev/rules.d/99-surface-pro-11-bluetooth-mac.rules", Reason: "the legacy Bluetooth udev trigger conflicts with the native hand-off service", Markers: []string{"SUBSYSTEM==\"bluetooth\"", "KERNEL==\"hci[0-9]*\"", "ENV{SYSTEMD_WANTS}=\"sp11-bluetooth-mac@%k.service\""}},
	{ID: "touch-modprobe", Feature: "touchscreen", Path: "etc/modprobe.d/sp11-touchscreen.conf", Reason: "the current kernel contains the touchscreen driver in-tree", Markers: []string{"mshw0485_touch"}},
	{ID: "touch-modules-load", Feature: "touchscreen", Path: "etc/modules-load.d/sp11-touchscreen.conf", Reason: "the current kernel contains the touchscreen driver in-tree", Markers: []string{"mshw0485_touch"}},
	{ID: "touch-initramfs-hook", Feature: "touchscreen", Path: "etc/initramfs-tools/hooks/sp11-touchscreen", Reason: "the current kernel contains the touchscreen driver in-tree", Markers: []string{"mshw0485_touch"}},
	{ID: "touch-dracut", Feature: "touchscreen", Path: "etc/dracut.conf.d/91-sp11-touchscreen.conf", Reason: "the current kernel contains the touchscreen driver in-tree", Markers: []string{"mshw0485_touch"}},
	{ID: "pen-g6-unit", Feature: "pen", Path: "etc/systemd/system/g6-pen.service", Reason: "production stylus input now uses the paired iptsd integration", Markers: []string{"g6-pen"}},
	{ID: "pen-g6-enablement", Feature: "pen", Path: "etc/systemd/system/multi-user.target.wants/g6-pen.service", Reason: "production stylus input now uses the paired iptsd integration", SymlinkTarget: "etc/systemd/system/g6-pen.service"},
}

// ScanOptions selects a target root and, optionally, one explicit
// target-visible user home for per-user legacy inspection.
type ScanOptions struct {
	// Root is the target Linux filesystem root.
	Root string
	// UserHome is an absolute canonical Linux path inside Root. It is never
	// inferred from the process environment or account database.
	UserHome string
}

// Finding records the current state of one path matching a clean-up rule.
type Finding struct {
	// Rule is the allow-listed clean-up rule that selected the path.
	Rule Rule `json:"rule"`
	// Path is the absolute target below ScanReport.Root.
	Path string `json:"path"`
	// SHA256 identifies regular-file content at scan time.
	SHA256 string `json:"sha256,omitempty"`
	// Size records the exact regular-file length without exposing its contents.
	Size int64 `json:"size,omitempty"`
	// Mode records the original permission bits needed for exact recovery.
	Mode uint32 `json:"mode"`
	// UID records the original numeric owner needed for exact recovery.
	UID uint32 `json:"uid"`
	// GID records the original numeric group needed for exact recovery.
	GID uint32 `json:"gid"`
	// ModifiedUnixNano records private-file changes without publishing a
	// brute-forceable digest of their contents.
	ModifiedUnixNano int64 `json:"modified_unix_nano"`
	// Kind describes whether the target is a regular file, symlink, or another
	// filesystem object.
	Kind string `json:"kind"`
	// SymlinkTarget records the unmodified link text used during revalidation.
	SymlinkTarget string `json:"symlink_target,omitempty"`
	// Recognized records whether the object has been recognised as safe for
	// automated removal.
	Recognized bool `json:"recognized"`
	// Details explains the finding and any reason manual review is required.
	Details string `json:"details"`
}

// ScanReport is a point-in-time clean-up plan for one resolved system root.
type ScanReport struct {
	// Root is the absolute, symlink-resolved boundary for every finding.
	Root string `json:"root"`
	// RootIdentity binds Root to the exact opened filesystem directory.
	RootIdentity DirectoryIdentity `json:"root_identity"`
	// UserHome is the explicit target-visible user home included in the scan.
	UserHome string `json:"user_home,omitempty"`
	// UserHomeIdentity binds UserHome to the exact opened directory when selected.
	UserHomeIdentity *DirectoryIdentity `json:"user_home_identity,omitempty"`
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
	// RootIdentity binds Root to the exact target directory used by Apply.
	RootIdentity DirectoryIdentity `json:"root_identity"`
	// UserHome is the explicit target-visible user home covered by the plan.
	UserHome string `json:"user_home,omitempty"`
	// UserHomeIdentity binds UserHome to the exact directory used by Apply.
	UserHomeIdentity *DirectoryIdentity `json:"user_home_identity,omitempty"`
	// Backup is the private directory holding copies of removed entries.
	Backup string `json:"backup"`
	// Changes maps each removed target to its recoverable backup.
	Changes []ReceiptItem `json:"changes"`
}

// applyOperations isolates the one destructive filesystem operation so tests
// can prove the recovery receipt exists before removal begins.
type applyOperations struct {
	// rename performs one descriptor-relative quarantine transition.
	rename func(*os.File, string, *os.File, string) error
	// remove deletes one descriptor-relative quarantine entry or directory.
	remove func(*os.Root, string) error
}

// anchoredChangePaths retains descriptor-relative names for one public receipt
// item throughout Apply.
type anchoredChangePaths struct {
	// parent is the stable immediate parent of the compiled rule target.
	parent anchoredParent
	// original is the one-component compiled rule name below parent.
	original string
	// quarantineDirectory is the private sibling directory below parent.
	quarantineDirectory string
	// quarantineRoot is the stable private workspace opened before mutation.
	quarantineRoot *os.Root
	// quarantineHandle is the stable workspace descriptor used by renameat.
	quarantineHandle *os.File
	// quarantine is the one-component renamed entry below quarantineRoot.
	quarantine string
	// backup is the recovery copy relative to the anchored backup root.
	backup string
}

// anchoredQuarantine identifies one empty pre-mutation workspace that can be
// removed safely through its stable root.
type anchoredQuarantine struct {
	// root confines removal to the original operation boundary.
	root *os.Root
	// name is the descriptor-relative quarantine directory.
	name string
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
	// HMACSHA256 authenticates private regular-file content without publishing a
	// brute-forceable content digest. Its key remains in the private backup.
	HMACSHA256 string `json:"hmac_sha256,omitempty"`
	// Size records the exact regular-file length.
	Size int64 `json:"size,omitempty"`
	// Mode records the original permission bits.
	Mode uint32 `json:"mode"`
	// UID records the original numeric owner.
	UID uint32 `json:"uid"`
	// GID records the original numeric group.
	GID uint32 `json:"gid"`
	// SymlinkTarget records exact link text for later integrity checks.
	SymlinkTarget string `json:"symlink_target,omitempty"`
}

// RestoreReport records entries restored from a clean-up receipt and entries
// that were already present with exactly the reviewed contents.
type RestoreReport struct {
	// Root is the resolved target root restored by the operation.
	Root string `json:"root"`
	// UserHome is the explicit target-visible user home covered by the receipt.
	UserHome string `json:"user_home,omitempty"`
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
	return ScanWithOptions(ScanOptions{Root: root})
}

// ScanWithOptions inspects fixed system paths and, when explicitly selected,
// fixed paths beneath one canonical target-visible user home.
func ScanWithOptions(options ScanOptions) (ScanReport, error) {
	roots, err := openAnchoredRoots(options.Root, options.UserHome)
	if err != nil {
		return ScanReport{}, err
	}
	defer roots.close()
	return scanAnchored(roots)
}

// scanAnchored reads every rule through stable target-root or user-home
// descriptors so a pathname swap cannot redirect inspection.
func scanAnchored(roots *anchoredRoots) (ScanReport, error) {
	report := ScanReport{
		Root: roots.rootPath, RootIdentity: roots.rootIdentity,
		UserHome: roots.userHome, UserHomeIdentity: roots.userIdentity,
	}
	for _, rule := range LegacyRules {
		location, selected, err := roots.locationForRule(rule)
		if err != nil {
			return ScanReport{}, err
		}
		if !selected {
			continue
		}
		logical := filepath.FromSlash(rule.Path)
		publicPath := filepath.Join(location.publicBase, logical)
		info, err := location.root.Lstat(logical)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return ScanReport{}, err
		}
		uid, gid, ownerErr := fileOwnership(info)
		if ownerErr != nil {
			return ScanReport{}, fmt.Errorf("inspect ownership of %s: %w", publicPath, ownerErr)
		}
		finding := Finding{Rule: rule, Path: publicPath, Details: rule.Reason, Mode: uint32(info.Mode().Perm()), UID: uid, GID: gid, ModifiedUnixNano: info.ModTime().UnixNano()}
		if info.Mode()&os.ModeSymlink != 0 {
			finding.Kind = "symlink"
			target, _, readErr := readAnchoredSymlink(location.root, logical)
			if readErr != nil {
				return ScanReport{}, readErr
			}
			finding.SymlinkTarget = target
			finding.Details += "; target=" + target
			if rule.SymlinkTarget == "" {
				finding.Details = "path is a symbolic link, but this rule permits only a regular file; manual review required"
			} else if anchoredSymlinkMatches(rule, roots.userHome, target) {
				finding.Recognized = true
			} else {
				finding.Details = "symbolic-link target does not match the known workaround; manual review required"
			}
		} else if info.Mode().IsRegular() {
			finding.Kind = "file"
			maximum := rule.maximumSize
			if maximum <= 0 {
				maximum = maximumLegacyFileBytes
			}
			data, readErr := readBoundedRootRegular(location.root, logical, maximum)
			if errors.Is(readErr, errLegacyFileTooLarge) {
				finding.Details = fmt.Sprintf("regular file exceeds the %d-byte recognition limit; manual review required", maximum)
				report.Findings = append(report.Findings, finding)
				continue
			}
			if readErr != nil {
				return ScanReport{}, readErr
			}
			unsupported, metadataErr := unsupportedAnchoredRecoveryMetadata(location.root, logical, info, 1)
			if metadataErr != nil {
				return ScanReport{}, fmt.Errorf("inspect recoverable metadata for %s: %w", publicPath, metadataErr)
			}
			finding.Size = int64(len(data))
			digest := sha256.Sum256(data)
			if !rule.privateContent {
				finding.SHA256 = hex.EncodeToString(digest[:])
			}
			if len(rule.Markers) == 0 {
				finding.Details = "path is a regular file, but this rule permits only a symbolic link; manual review required"
			} else {
				finding.Recognized = true
				if len(rule.prefix) != 0 && !strings.HasPrefix(string(data), string(rule.prefix)) {
					finding.Recognized = false
					finding.Details = "path matches a legacy workaround, but its file signature differs; manual review required"
				}
				for _, marker := range rule.Markers {
					if finding.Recognized && !strings.Contains(string(data), marker) {
						finding.Recognized = false
						finding.Details = "path matches a legacy workaround, but a content marker is absent; manual review required"
						break
					}
				}
				if finding.Recognized && rule.validateContent != nil && !rule.validateContent(data) {
					finding.Recognized = false
					finding.Details = "path matches a legacy workaround, but its format differs; manual review required"
				}
			}
			if unsupported != "" {
				finding.Recognized = false
				finding.Details = unsupported + "; manual review required"
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

// anchoredSymlinkMatches compares link text using target-root semantics without
// following the leaf or allowing a per-user link to resolve outside its home.
func anchoredSymlinkMatches(rule Rule, userHome, target string) bool {
	expected := path.Clean(filepath.ToSlash(rule.SymlinkTarget))
	if strings.HasPrefix(target, "/") {
		absolute := path.Clean(filepath.ToSlash(target))
		if rule.scope == ruleScopeUser {
			prefix := strings.TrimSuffix(path.Clean(userHome), "/") + "/"
			if !strings.HasPrefix(absolute, prefix) {
				return false
			}
			return strings.TrimPrefix(absolute, prefix) == expected
		}
		return strings.TrimPrefix(absolute, "/") == expected
	}
	resolved := path.Clean(path.Join(path.Dir(filepath.ToSlash(rule.Path)), filepath.ToSlash(target)))
	return resolved != ".." && !strings.HasPrefix(resolved, "../") && resolved == expected
}

// validLegacyBluetoothConfig accepts only the closed assignment vocabulary
// written by historical versions of the retired helper. It validates the
// private address in memory without returning or hashing it.
func validLegacyBluetoothConfig(data []byte) bool {
	allowed := map[string]string{
		"SP11_BLUETOOTH_MAC":                      "address",
		"SP11_BLUETOOTH_HCI":                      "controller",
		"SP11_BLUETOOTH_ATTEMPTS":                 "integer",
		"SP11_BLUETOOTH_SETTLE_SECONDS":           "integer",
		"SP11_BLUETOOTH_BTMGMT_TIMEOUT":           "integer",
		"SP11_BLUETOOTH_RESTART_BLUETOOTH_BEFORE": "boolean",
		"SP11_BLUETOOTH_NO_BATCH":                 "boolean",
	}
	seen := make(map[string]bool, len(allowed))
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "#") {
			if line != "# Surface Pro 11 Bluetooth MAC address." && line != "# Use the address reported by Windows or another trusted source." {
				return false
			}
			continue
		}
		name, encoded, found := strings.Cut(line, "=")
		kind, known := allowed[name]
		if !found || !known || seen[name] || len(encoded) < 2 || encoded[0] != '"' || encoded[len(encoded)-1] != '"' {
			return false
		}
		value := encoded[1 : len(encoded)-1]
		if strings.ContainsAny(value, "\"\\`$") || !validLegacyBluetoothValue(kind, value) {
			return false
		}
		seen[name] = true
	}
	return seen["SP11_BLUETOOTH_MAC"] && seen["SP11_BLUETOOTH_HCI"]
}

// validLegacyBluetoothValue validates one private legacy configuration value
// against its closed, non-executable scalar kind.
func validLegacyBluetoothValue(kind, value string) bool {
	switch kind {
	case "address":
		if len(value) != 17 || strings.ToUpper(value) != value {
			return false
		}
		for index := 0; index < 6; index++ {
			start := index * 3
			if index < 5 && value[start+2] != ':' {
				return false
			}
			if _, err := hex.DecodeString(value[start : start+2]); err != nil {
				return false
			}
		}
		return true
	case "controller":
		if !strings.HasPrefix(value, "hci") || len(value) <= 3 {
			return false
		}
		controller, err := strconv.ParseUint(strings.TrimPrefix(value, "hci"), 10, 16)
		return err == nil && controller <= 65535
	case "integer":
		integer, err := strconv.ParseUint(value, 10, 31)
		return err == nil && integer > 0 && integer <= 86400
	case "boolean":
		return value == "true" || value == "false"
	default:
		return false
	}
}

// validLegacyBluetoothUnit accepts both the historical shell helper and the
// later raw-management helper as the sole service command.
func validLegacyBluetoothUnit(data []byte) bool {
	knownCommands := map[string]bool{
		"ExecStart=/usr/local/sbin/sp11-bluetooth-mac --apply --hci %I":                                                                                  true,
		"ExecStart=/usr/local/sbin/sp11-bluetooth-mac --apply --hci %I --no-batch --attempts 3 --settle-seconds 1 --btmgmt-timeout 15":                   true,
		"ExecStart=/usr/local/sbin/sp11-bluetooth-mac --apply --hci %I --no-batch --attempts 3 --settle-seconds 120 --btmgmt-timeout 120":                true,
		"ExecStart=/usr/local/sbin/sp11-bluetooth-mac --apply --hci %I --no-batch --attempts 3 --settle-seconds 300 --btmgmt-timeout 120":                true,
		"ExecStart=/usr/local/sbin/sp11-bluetooth-mac --apply --hci %I --no-batch --attempts 3 --settle-seconds 60 --btmgmt-timeout 15":                  true,
		"ExecStart=/usr/local/sbin/sp11-bluetooth-mac --apply --hci %I --no-batch --attempts 3 --settle-seconds 60 --btmgmt-timeout 60":                  true,
		"ExecStart=/usr/local/sbin/sp11-bluetooth-mac --apply --hci %I --restart-bluetooth-before --attempts 12 --settle-seconds 20 --btmgmt-timeout 12": true,
		"ExecStart=/usr/local/sbin/sp11-bt-set-addr 0 ${SP11_BLUETOOTH_MAC}":                                                                             true,
	}
	execStarts := 0
	validExecStart := false
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)
		if !strings.HasPrefix(line, "ExecStart=") {
			continue
		}
		execStarts++
		validExecStart = knownCommands[line]
	}
	return execStarts == 1 && validExecStart
}

// errLegacyFileTooLarge identifies a bounded recognition read that refused an
// oversized regular file without consuming its contents.
var errLegacyFileTooLarge = errors.New("legacy file exceeds the recognition limit")

// readBoundedRootRegular opens one regular file relative to a stable root and
// reads it through the recognition ceiling without following an escaping link.
func readBoundedRootRegular(root *os.Root, name string, maximum int64) ([]byte, error) {
	before, err := root.Lstat(name)
	if err != nil {
		return nil, err
	}
	if before.Mode()&os.ModeSymlink != 0 || !before.Mode().IsRegular() {
		return nil, errors.New("anchored entry is not a regular file")
	}
	file, err := root.Open(name)
	if err != nil {
		return nil, err
	}
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(before, opened) {
		_ = file.Close()
		return nil, errors.Join(err, errors.New("anchored regular file changed while it was opened"))
	}
	afterOpen, err := root.Lstat(name)
	if err != nil || !os.SameFile(before, afterOpen) {
		_ = file.Close()
		return nil, errors.Join(err, errors.New("anchored regular file changed while it was opened"))
	}
	data, readErr := readBoundedOpenRegular(file, maximum)
	afterRead, afterErr := root.Lstat(name)
	if afterErr != nil || !os.SameFile(before, afterRead) {
		return nil, errors.Join(readErr, afterErr, errors.New("anchored regular file changed while it was read"))
	}
	if readErr != nil {
		return nil, readErr
	}
	return data, nil
}

// readBoundedOpenRegular validates and consumes one already opened file,
// closing it exactly once on every return path.
func readBoundedOpenRegular(file *os.File, maximum int64) ([]byte, error) {
	info, statErr := file.Stat()
	if statErr != nil {
		_ = file.Close()
		return nil, statErr
	}
	if !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > maximum {
		_ = file.Close()
		return nil, errLegacyFileTooLarge
	}
	data, readErr := io.ReadAll(io.LimitReader(file, maximum+1))
	closeErr := file.Close()
	if err := errors.Join(readErr, closeErr); err != nil {
		return nil, err
	}
	if int64(len(data)) > maximum {
		return nil, errLegacyFileTooLarge
	}
	return data, nil
}

// fileOwnership returns portable numeric ownership from Unix file metadata.
func fileOwnership(info os.FileInfo) (uint32, uint32, error) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, 0, errors.New("filesystem metadata has no Unix ownership")
	}
	return stat.Uid, stat.Gid, nil
}

// ResolveUserHome validates one explicit target-visible absolute Linux home and
// returns its canonical logical form. Empty input deliberately selects no home.
func ResolveUserHome(root, userHome string) (string, error) {
	if userHome == "" {
		return "", nil
	}
	if strings.TrimSpace(userHome) != userHome || strings.Contains(userHome, "\\") || !filepath.IsAbs(userHome) {
		return "", fmt.Errorf("cleanup user home must be an explicit absolute Linux path: %q", userHome)
	}
	clean := filepath.Clean(userHome)
	if clean != userHome || clean == string(filepath.Separator) {
		return "", fmt.Errorf("cleanup user home must be canonical and cannot be /: %q", userHome)
	}
	resolvedRoot, err := ResolveRoot(root)
	if err != nil {
		return "", err
	}
	relative := strings.TrimPrefix(clean, string(filepath.Separator))
	hostPath, err := safeJoin(resolvedRoot, relative)
	if err != nil {
		return "", fmt.Errorf("resolve cleanup user home: %w", err)
	}
	info, err := os.Lstat(hostPath)
	if err != nil {
		return "", fmt.Errorf("inspect cleanup user home %q: %w", clean, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", fmt.Errorf("cleanup user home must be a real directory: %q", clean)
	}
	resolvedHome, err := filepath.EvalSymlinks(hostPath)
	if err != nil {
		return "", fmt.Errorf("resolve cleanup user home %q: %w", clean, err)
	}
	if resolvedHome != hostPath || !withinRoot(resolvedRoot, resolvedHome) {
		return "", fmt.Errorf("cleanup user home is not canonical within the selected root: %q", clean)
	}
	return filepath.ToSlash(clean), nil
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
	return restore(receipt, receiptPath, yes, restoreOperations{
		link:    linkAnchoredDirectories,
		symlink: func(root *os.Root, oldName, newName string) error { return root.Symlink(oldName, newName) },
	})
}

// restore performs recovery through stable roots with injectable no-overwrite
// publication boundaries for hostile ancestor-swap tests.
func restore(receipt Receipt, receiptPath string, yes bool, operations restoreOperations) (RestoreReport, error) {
	report := RestoreReport{Root: receipt.Root, UserHome: receipt.UserHome, Receipt: receiptPath}
	if !yes {
		return report, errors.New("cleanup restore requires --yes after reviewing the receipt")
	}
	if operations.link == nil || operations.symlink == nil {
		return report, errors.New("cleanup restoration operations are unavailable")
	}
	if err := validateReceipt(receipt); err != nil {
		return report, err
	}
	roots, err := openAnchoredRoots(receipt.Root, receipt.UserHome)
	if err != nil {
		return report, err
	}
	defer roots.close()
	if err := roots.requireIdentities(receipt.RootIdentity, receipt.UserHomeIdentity); err != nil {
		return report, err
	}
	if len(receipt.Changes) == 0 {
		return report, nil
	}
	backupRelative, err := filepath.Rel(receipt.Root, receipt.Backup)
	if err != nil {
		return report, fmt.Errorf("resolve cleanup backup: %w", err)
	}
	backupRoot, err := openAnchoredBackupRoot(roots.target, receipt.Root, backupRelative)
	if err != nil {
		return report, fmt.Errorf("validate cleanup backup hierarchy: %w", err)
	}
	defer backupRoot.Close()
	integrityKey, err := readAnchoredPrivateIntegrityKey(backupRoot, receipt)
	if err != nil {
		return report, err
	}
	for _, change := range receipt.Changes {
		alreadyPresent, err := restoreReceiptItem(roots, backupRoot, receipt, change, integrityKey, operations)
		if err != nil {
			return report, err
		}
		if alreadyPresent {
			report.AlreadyPresent = append(report.AlreadyPresent, change.Original)
		} else {
			report.Restored = append(report.Restored, change.Original)
		}
	}
	return report, nil
}

// restoreReceiptItem verifies and recovers one receipt entry through stable
// immediate-parent and recovery-source descriptors.
func restoreReceiptItem(roots *anchoredRoots, backupRoot *os.Root, receipt Receipt, change ReceiptItem, integrityKey []byte, operations restoreOperations) (bool, error) {
	rule := compiledRule(change.RuleID)
	location, selected, err := roots.locationForRule(rule)
	if err != nil {
		return false, err
	}
	if !selected {
		return false, fmt.Errorf("cleanup receipt rule %s requires an explicit user home", change.RuleID)
	}
	destination, err := openAnchoredParent(location, filepath.FromSlash(rule.Path))
	if err != nil {
		return false, fmt.Errorf("open restoration parent for %s: %w", change.Original, err)
	}
	defer destination.close()
	if _, err := destination.location.root.Lstat(destination.leaf); err == nil {
		if verifyAnchoredReceiptEntry(destination.location.root, destination.leaf, change, integrityKey) != nil {
			return false, fmt.Errorf("refuse to overwrite changed restoration target %s", change.Original)
		}
		return true, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return false, fmt.Errorf("inspect restoration target %s: %w", change.Original, err)
	}
	backupName, err := filepath.Rel(receipt.Backup, change.BackupPath)
	if err != nil {
		return false, fmt.Errorf("resolve recovery copy %s: %w", change.BackupPath, err)
	}
	sourceParent, sourceErr := openAnchoredParent(anchoredLocation{root: backupRoot, publicBase: receipt.Backup}, backupName)
	var backupFailure error
	if sourceErr == nil {
		if _, statErr := sourceParent.location.root.Lstat(sourceParent.leaf); statErr == nil {
			source := anchoredRecoverySource{root: sourceParent.location.root, name: sourceParent.leaf, publicPath: change.BackupPath}
			if err := verifyAnchoredReceiptEntry(source.root, source.name, change, integrityKey); err != nil {
				backupFailure = fmt.Errorf("verify recovery copy for %s: %w", change.Original, err)
			} else {
				restoreErr := restoreAnchoredEntry(destination, source, change, integrityKey, operations)
				closeErr := sourceParent.close()
				if err := errors.Join(restoreErr, closeErr); err != nil {
					return false, err
				}
				return false, nil
			}
		} else if !errors.Is(statErr, os.ErrNotExist) {
			_ = sourceParent.close()
			return false, fmt.Errorf("inspect recovery copy %s: %w", change.BackupPath, statErr)
		}
		_ = sourceParent.close()
	} else if !errors.Is(sourceErr, os.ErrNotExist) {
		return false, fmt.Errorf("open recovery copy parent %s: %w", change.BackupPath, sourceErr)
	}
	if change.QuarantinePath == "" {
		if backupFailure != nil {
			return false, backupFailure
		}
		return false, fmt.Errorf("no recovery copy remains for %s", change.Original)
	}
	quarantineDirectory := filepath.Base(filepath.Dir(change.QuarantinePath))
	quarantineRoot, _, err := openStableChildRoot(destination.location.root, quarantineDirectory)
	if err != nil {
		return false, errors.Join(backupFailure, fmt.Errorf("open quarantined recovery copy for %s: %w", change.Original, err))
	}
	defer quarantineRoot.Close()
	source := anchoredRecoverySource{root: quarantineRoot, name: filepath.Base(change.QuarantinePath), publicPath: change.QuarantinePath}
	if err := verifyAnchoredReceiptEntry(source.root, source.name, change, integrityKey); err != nil {
		return false, errors.Join(backupFailure, fmt.Errorf("verify quarantined recovery copy for %s: %w", change.Original, err))
	}
	if err := restoreAnchoredEntry(destination, source, change, integrityKey, operations); err != nil {
		return false, err
	}
	return false, nil
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
	resolvedUserHome, err := ResolveUserHome(receipt.Root, receipt.UserHome)
	if err != nil {
		return err
	}
	if resolvedUserHome != receipt.UserHome {
		return fmt.Errorf("cleanup receipt user home is not canonical: %s", receipt.UserHome)
	}
	if !receipt.RootIdentity.valid() {
		return errors.New("cleanup receipt has no valid target-root identity")
	}
	if receipt.UserHome == "" && receipt.UserHomeIdentity != nil {
		return errors.New("cleanup receipt has a user-home identity without a selected home")
	}
	if receipt.UserHome != "" && (receipt.UserHomeIdentity == nil || !receipt.UserHomeIdentity.valid()) {
		return errors.New("cleanup receipt has no valid selected user-home identity")
	}
	if len(receipt.Changes) == 0 && receipt.Backup == "" {
		return nil
	}
	backupParent := filepath.Join(receipt.Root, filepath.FromSlash("var/lib/linux-armer/backups"))
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
		base := receipt.Root
		if rule.scope == ruleScopeUser {
			if receipt.UserHome == "" {
				return fmt.Errorf("cleanup receipt rule %s requires an explicit user home", change.RuleID)
			}
			base = filepath.Join(receipt.Root, strings.TrimPrefix(filepath.FromSlash(receipt.UserHome), string(filepath.Separator)))
		} else if rule.scope != ruleScopeSystem {
			return fmt.Errorf("cleanup receipt rule %s has an unknown scope", change.RuleID)
		}
		if base == "" {
			return fmt.Errorf("cleanup receipt rule %s requires an explicit user home", change.RuleID)
		}
		expectedOriginal := filepath.Join(base, filepath.FromSlash(rule.Path))
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
			if change.Size < 0 || change.Mode > 0o777 {
				return fmt.Errorf("cleanup receipt has invalid file metadata for rule %s", change.RuleID)
			}
			if rule.privateContent {
				digest, digestErr := hex.DecodeString(change.HMACSHA256)
				if change.SHA256 != "" || digestErr != nil || len(digest) != sha256.Size {
					return fmt.Errorf("cleanup receipt has invalid private integrity tag for rule %s", change.RuleID)
				}
			} else {
				digest, digestErr := hex.DecodeString(change.SHA256)
				if change.HMACSHA256 != "" || digestErr != nil || len(digest) != sha256.Size {
					return fmt.Errorf("cleanup receipt has invalid SHA-256 for rule %s", change.RuleID)
				}
			}
		case "symlink":
			if change.SymlinkTarget == "" || change.SHA256 != "" || change.HMACSHA256 != "" || change.Mode > 0o777 {
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

// Apply backs up and removes recognised findings. Unrecognised content is
// never removed.
func Apply(report ScanReport, yes bool) (Receipt, error) {
	return apply(report, yes, applyOperations{
		rename: renameAnchoredDirectories,
		remove: func(root *os.Root, name string) error { return root.Remove(name) },
	})
}

// renameAnchoredDirectories moves one entry between stable directory
// descriptors without resolving either directory through a mutable pathname.
func renameAnchoredDirectories(source *os.File, sourceName string, destination *os.File, destinationName string) error {
	return unix.Renameat(int(source.Fd()), sourceName, int(destination.Fd()), destinationName)
}

// apply performs the clean-up transaction with an injectable removal boundary.
func apply(report ScanReport, yes bool, operations applyOperations) (Receipt, error) {
	if !yes {
		return Receipt{}, errors.New("cleanup apply requires --yes after reviewing clean plan")
	}
	if operations.rename == nil || operations.remove == nil {
		return Receipt{}, errors.New("cleanup filesystem operations are unavailable")
	}
	roots, err := openAnchoredRoots(report.Root, report.UserHome)
	if err != nil {
		return Receipt{}, err
	}
	defer roots.close()
	if err := roots.requireIdentities(report.RootIdentity, report.UserHomeIdentity); err != nil {
		return Receipt{}, err
	}
	validatedFindings, err := revalidateFindings(report, roots)
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
		return Receipt{
			State: "complete", CreatedAt: time.Now().UTC(), Root: report.Root,
			RootIdentity: roots.rootIdentity, UserHome: report.UserHome, UserHomeIdentity: roots.userIdentity,
		}, nil
	}
	stamp := time.Now().UTC().Format("20060102T150405.000000000Z")
	backupParentRelative := filepath.FromSlash("var/lib/linux-armer/backups")
	if err := ensureAnchoredBackupParent(roots.target, report.Root); err != nil {
		return Receipt{}, fmt.Errorf("create cleanup backup parent: %w", err)
	}
	backupParentRoot, err := openAnchoredBackupParentRoot(roots.target, report.Root)
	if err != nil {
		return Receipt{}, fmt.Errorf("open cleanup backup parent: %w", err)
	}
	defer backupParentRoot.Close()
	backupRelative := filepath.Join(backupParentRelative, stamp)
	backup := filepath.Join(report.Root, backupRelative)
	if err := backupParentRoot.Mkdir(stamp, 0o700); err != nil {
		return Receipt{}, fmt.Errorf("create cleanup backup: %w", err)
	}
	backupDirectory, err := backupParentRoot.Open(stamp)
	if err != nil {
		return Receipt{}, fmt.Errorf("open cleanup backup: %w", err)
	}
	chmodErr := backupDirectory.Chmod(0o700)
	syncErr := backupDirectory.Sync()
	closeErr := backupDirectory.Close()
	if err := errors.Join(chmodErr, syncErr, closeErr); err != nil {
		return Receipt{}, fmt.Errorf("protect cleanup backup: %w", err)
	}
	backupInfo, err := backupParentRoot.Lstat(stamp)
	if err != nil {
		return Receipt{}, fmt.Errorf("inspect cleanup backup: %w", err)
	}
	if err := validatePrivateDirectoryInfo(backup, backupInfo); err != nil {
		return Receipt{}, fmt.Errorf("validate cleanup backup: %w", err)
	}
	if err := syncAnchoredDirectory(backupParentRoot, "."); err != nil {
		return Receipt{}, fmt.Errorf("persist cleanup backup directory: %w", err)
	}
	backupRoot, _, err := openStableChildRoot(backupParentRoot, stamp)
	if err != nil {
		return Receipt{}, fmt.Errorf("open anchored cleanup backup: %w", err)
	}
	defer backupRoot.Close()
	privateIntegrityRequired := false
	for _, finding := range recognised {
		if compiledRule(finding.Rule.ID).privateContent {
			privateIntegrityRequired = true
			break
		}
	}
	var integrityKey []byte
	if privateIntegrityRequired {
		integrityKey, err = createAnchoredPrivateIntegrityKey(backupRoot)
		if err != nil {
			return Receipt{}, fmt.Errorf("create private cleanup integrity key: %w", err)
		}
	}
	receipt := Receipt{
		State: "prepared", CreatedAt: time.Now().UTC(), Root: report.Root,
		RootIdentity: roots.rootIdentity, UserHome: report.UserHome, UserHomeIdentity: roots.userIdentity,
		Backup: backup,
	}
	findingByRule := make(map[string]Finding, len(recognised))
	pathsByRule := make(map[string]anchoredChangePaths, len(recognised))
	quarantineDirectories := make([]anchoredQuarantine, 0, len(recognised))
	openedParents := make([]anchoredParent, 0, len(recognised))
	openedQuarantines := make([]*os.Root, 0, len(recognised))
	openedQuarantineHandles := make([]*os.File, 0, len(recognised))
	defer func() {
		for _, handle := range openedQuarantineHandles {
			_ = handle.Close()
		}
		for _, quarantineRoot := range openedQuarantines {
			_ = quarantineRoot.Close()
		}
		for _, parent := range openedParents {
			_ = parent.close()
		}
	}()
	for _, finding := range recognised {
		rule := compiledRule(finding.Rule.ID)
		location, selected, err := roots.locationForRule(rule)
		if err != nil {
			return Receipt{}, fmt.Errorf("select anchored cleanup location for %s: %w", finding.Rule.ID, err)
		}
		if !selected {
			return Receipt{}, fmt.Errorf("select anchored cleanup location for %s: explicit user home is absent", finding.Rule.ID)
		}
		parent, err := openAnchoredParent(location, filepath.FromSlash(rule.Path))
		if err != nil {
			return Receipt{}, fmt.Errorf("open stable cleanup parent for %s: %w", finding.Path, err)
		}
		openedParents = append(openedParents, parent)
		originalName := parent.leaf
		relative, err := filepath.Rel(report.Root, finding.Path)
		if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return Receipt{}, fmt.Errorf("unsafe cleanup path %s", finding.Path)
		}
		backupPath := filepath.Join(backup, relative)
		quarantineDirectoryName := ".linux-armer-cleanup-" + stamp + "-" + finding.Rule.ID
		quarantineDirectory := filepath.Join(parent.location.publicBase, quarantineDirectoryName)
		if err := parent.location.root.Mkdir(quarantineDirectoryName, 0o700); err != nil {
			removeAnchoredEmptyDirectories(quarantineDirectories)
			return Receipt{}, fmt.Errorf("create cleanup quarantine beside %s: %w", finding.Path, err)
		}
		quarantineDirectories = append(quarantineDirectories, anchoredQuarantine{root: parent.location.root, name: quarantineDirectoryName})
		quarantineHandle, err := parent.location.root.Open(quarantineDirectoryName)
		if err != nil {
			removeAnchoredEmptyDirectories(quarantineDirectories)
			return Receipt{}, fmt.Errorf("open cleanup quarantine beside %s: %w", finding.Path, err)
		}
		chmodErr := quarantineHandle.Chmod(0o700)
		syncErr := quarantineHandle.Sync()
		closeErr := quarantineHandle.Close()
		if err := errors.Join(chmodErr, syncErr, closeErr); err != nil {
			removeAnchoredEmptyDirectories(quarantineDirectories)
			return Receipt{}, fmt.Errorf("protect cleanup quarantine beside %s: %w", finding.Path, err)
		}
		if err := syncAnchoredDirectory(parent.location.root, "."); err != nil {
			removeAnchoredEmptyDirectories(quarantineDirectories)
			return Receipt{}, fmt.Errorf("persist cleanup quarantine beside %s: %w", finding.Path, err)
		}
		quarantineRoot, _, err := openStableChildRoot(parent.location.root, quarantineDirectoryName)
		if err != nil {
			removeAnchoredEmptyDirectories(quarantineDirectories)
			return Receipt{}, fmt.Errorf("anchor cleanup quarantine beside %s: %w", finding.Path, err)
		}
		openedQuarantines = append(openedQuarantines, quarantineRoot)
		quarantineDirectoryHandle, err := quarantineRoot.Open(".")
		if err != nil {
			removeAnchoredEmptyDirectories(quarantineDirectories)
			return Receipt{}, fmt.Errorf("open cleanup quarantine descriptor beside %s: %w", finding.Path, err)
		}
		openedQuarantineHandles = append(openedQuarantineHandles, quarantineDirectoryHandle)
		quarantineName := filepath.Base(originalName)
		quarantinePath := filepath.Join(quarantineDirectory, quarantineName)
		change := ReceiptItem{
			RuleID: finding.Rule.ID, Original: finding.Path, BackupPath: backupPath,
			QuarantinePath: quarantinePath, Kind: finding.Kind, SHA256: finding.SHA256,
			SymlinkTarget: finding.SymlinkTarget, Size: finding.Size, Mode: finding.Mode,
			UID: finding.UID, GID: finding.GID,
		}
		if rule.privateContent {
			privateBytes, validationErr := validateAnchoredRuleContent(parent.location.root, originalName, rule, finding)
			if validationErr != nil {
				removeAnchoredEmptyDirectories(quarantineDirectories)
				return Receipt{}, fmt.Errorf("revalidate private cleanup target %s: %w", finding.Path, validationErr)
			}
			change.SHA256 = ""
			change.HMACSHA256, err = hmacPrivateBytes(privateBytes, integrityKey)
			if err != nil {
				removeAnchoredEmptyDirectories(quarantineDirectories)
				return Receipt{}, fmt.Errorf("authenticate private cleanup target %s: %w", finding.Path, err)
			}
		}
		receipt.Changes = append(receipt.Changes, change)
		findingByRule[finding.Rule.ID] = finding
		pathsByRule[finding.Rule.ID] = anchoredChangePaths{
			parent: parent, original: originalName, quarantineDirectory: quarantineDirectoryName,
			quarantineRoot: quarantineRoot, quarantineHandle: quarantineDirectoryHandle,
			quarantine: quarantineName, backup: relative,
		}
	}
	for _, change := range receipt.Changes {
		paths := pathsByRule[change.RuleID]
		if _, err := verifyAnchoredFinding(paths.parent.location.root, paths.original, findingByRule[change.RuleID], change, integrityKey); err != nil {
			removeAnchoredEmptyDirectories(quarantineDirectories)
			return Receipt{}, fmt.Errorf("cleanup target %s changed before backup: %w", change.Original, err)
		}
		if err := ensureAnchoredPrivateDirectories(backupRoot, filepath.Dir(paths.backup)); err != nil {
			removeAnchoredEmptyDirectories(quarantineDirectories)
			return Receipt{}, fmt.Errorf("prepare backup for %s: %w", change.Original, err)
		}
		if err := copyAnchoredEntry(paths.parent.location.root, paths.original, backupRoot, paths.backup); err != nil {
			removeAnchoredEmptyDirectories(quarantineDirectories)
			return Receipt{}, fmt.Errorf("back up %s before mutation: %w", change.Original, err)
		}
		if err := syncAnchoredDirectory(backupRoot, filepath.Dir(paths.backup)); err != nil {
			removeAnchoredEmptyDirectories(quarantineDirectories)
			return Receipt{}, fmt.Errorf("persist backup for %s: %w", change.Original, err)
		}
		if err := verifyAnchoredReceiptEntry(backupRoot, paths.backup, change, integrityKey); err != nil {
			removeAnchoredEmptyDirectories(quarantineDirectories)
			return Receipt{}, fmt.Errorf("verify backup for %s: %w", change.Original, err)
		}
	}
	pendingReceiptName := "receipt.pending.json"
	pendingReceiptPath := filepath.Join(backup, pendingReceiptName)
	if err := writeAnchoredJSON(backupRoot, pendingReceiptName, receipt); err != nil {
		removeAnchoredEmptyDirectories(quarantineDirectories)
		return Receipt{}, fmt.Errorf("write cleanup recovery receipt before removal: %w", err)
	}
	if err := syncAnchoredDirectory(backupRoot, "."); err != nil {
		return Receipt{}, fmt.Errorf("persist cleanup recovery data: %w", err)
	}
	for _, change := range receipt.Changes {
		paths := pathsByRule[change.RuleID]
		beforeRename, err := verifyAnchoredFinding(paths.parent.location.root, paths.original, findingByRule[change.RuleID], change, integrityKey)
		if err != nil {
			return receipt, fmt.Errorf("cleanup target %s changed before quarantine: %w; recovery map: %s", change.Original, err, pendingReceiptPath)
		}
		if err := operations.rename(paths.parent.handle, paths.original, paths.quarantineHandle, paths.quarantine); err != nil {
			return receipt, fmt.Errorf("quarantine %s: %w; recovery map: %s", change.Original, err, pendingReceiptPath)
		}
		if err := syncAnchoredDirectory(paths.parent.location.root, "."); err != nil {
			return receipt, fmt.Errorf("persist quarantine of %s: %w; recovery map: %s", change.Original, err, pendingReceiptPath)
		}
		if err := syncAnchoredDirectory(paths.quarantineRoot, "."); err != nil {
			return receipt, fmt.Errorf("persist quarantined copy of %s: %w; recovery map: %s", change.Original, err, pendingReceiptPath)
		}
		quarantined, err := verifyAnchoredFinding(paths.quarantineRoot, paths.quarantine, findingByRule[change.RuleID], change, integrityKey)
		if err != nil || !os.SameFile(beforeRename, quarantined) {
			return receipt, fmt.Errorf("quarantined entry for %s no longer matches the reviewed plan: %w; inspect %s and %s", change.Original, err, change.QuarantinePath, pendingReceiptPath)
		}
		if err := operations.remove(paths.quarantineRoot, paths.quarantine); err != nil {
			return receipt, fmt.Errorf("remove quarantined copy for %s: %w; recover from %s or %s", change.Original, err, change.BackupPath, change.QuarantinePath)
		}
		if err := syncAnchoredDirectory(paths.quarantineRoot, "."); err != nil {
			return receipt, fmt.Errorf("persist removal of quarantined copy for %s: %w; recovery map: %s", change.Original, err, pendingReceiptPath)
		}
		visibleQuarantine, visibleErr := anchoredDirectoryIsVisible(paths.parent.location.root, paths.quarantineDirectory, paths.quarantineRoot)
		if err := paths.quarantineRoot.Close(); err != nil {
			return receipt, fmt.Errorf("close cleanup quarantine for %s: %w", change.Original, err)
		}
		if err := paths.quarantineHandle.Close(); err != nil {
			return receipt, fmt.Errorf("close cleanup quarantine descriptor for %s: %w", change.Original, err)
		}
		if visibleErr != nil {
			return receipt, fmt.Errorf("revalidate cleanup quarantine route %s: %w; recovery map: %s", filepath.Dir(change.QuarantinePath), visibleErr, pendingReceiptPath)
		}
		if !visibleQuarantine {
			return receipt, fmt.Errorf("cleanup quarantine route changed before directory removal: %s; recovery map: %s", filepath.Dir(change.QuarantinePath), pendingReceiptPath)
		}
		if err := operations.remove(paths.parent.location.root, paths.quarantineDirectory); err != nil {
			return receipt, fmt.Errorf("remove empty cleanup quarantine %s: %w; recovery map: %s", filepath.Dir(change.QuarantinePath), err, pendingReceiptPath)
		}
		if err := syncAnchoredDirectory(paths.parent.location.root, "."); err != nil {
			return receipt, fmt.Errorf("persist removal of cleanup quarantine %s: %w; recovery map: %s", filepath.Dir(change.QuarantinePath), err, pendingReceiptPath)
		}
	}
	receipt.State = "complete"
	receiptName := "receipt.json"
	if err := writeAnchoredJSON(backupRoot, receiptName, receipt); err != nil {
		return receipt, fmt.Errorf("write completed cleanup receipt: %w; recovery receipt remains at %s", err, pendingReceiptPath)
	}
	if err := syncAnchoredDirectory(backupRoot, "."); err != nil {
		return receipt, fmt.Errorf("persist completed cleanup receipt: %w; recovery receipt remains at %s", err, pendingReceiptPath)
	}
	if err := backupRoot.Remove(pendingReceiptName); err != nil {
		return receipt, fmt.Errorf("remove superseded recovery receipt %s: %w", pendingReceiptPath, err)
	}
	if err := syncAnchoredDirectory(backupRoot, "."); err != nil {
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

// validatePrivateDirectoryInfo applies the private recovery-directory contract
// to metadata that has already been read without following symbolic links.
func validatePrivateDirectoryInfo(path string, info os.FileInfo) error {
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("private cleanup directory is not a real directory: %s", path)
	}
	if info.Mode().Perm() != 0o700 {
		return fmt.Errorf("private cleanup directory must have mode 0700: %s", path)
	}
	uid, _, err := fileOwnership(info)
	if err != nil {
		return fmt.Errorf("inspect private cleanup directory ownership %s: %w", path, err)
	}
	if uid != uint32(os.Geteuid()) {
		return fmt.Errorf("private cleanup directory is not owned by the effective user: %s", path)
	}
	return nil
}

// validateTrustedDirectoryInfo rejects mutable or untrusted ordinary ancestors
// that could replace the private recovery hierarchy after it is checked.
func validateTrustedDirectoryInfo(path string, info os.FileInfo) error {
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("cleanup directory path is not a real directory: %s", path)
	}
	if info.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("cleanup directory is writable by group or others: %s", path)
	}
	uid, _, err := fileOwnership(info)
	if err != nil {
		return fmt.Errorf("inspect cleanup directory ownership %s: %w", path, err)
	}
	if uid != 0 && uid != uint32(os.Geteuid()) {
		return fmt.Errorf("cleanup directory is not owned by root or the effective user: %s", path)
	}
	return nil
}

// compiledRule returns the immutable rule fields for a stable identifier.
func compiledRule(id string) Rule {
	for _, rule := range LegacyRules {
		if rule.ID == id {
			return rule
		}
	}
	return Rule{}
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
func revalidateFindings(report ScanReport, roots *anchoredRoots) ([]Finding, error) {
	current, err := scanAnchored(roots)
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
		if !known || !samePublicRule(planned.Rule, rule) || seen[rule.ID] {
			return nil, fmt.Errorf("cleanup plan contains an unknown or duplicate rule %q", planned.Rule.ID)
		}
		seen[rule.ID] = true
		location, selected, err := roots.locationForRule(rule)
		if err != nil {
			return nil, err
		}
		if !selected {
			return nil, fmt.Errorf("cleanup plan rule %s requires an explicit user home", rule.ID)
		}
		expectedPath := filepath.Join(location.publicBase, filepath.FromSlash(rule.Path))
		if filepath.Clean(planned.Path) != expectedPath {
			return nil, fmt.Errorf("cleanup plan path changed for rule %s", rule.ID)
		}
		observed, exists := currentByID[rule.ID]
		if !exists {
			return nil, fmt.Errorf("cleanup target changed after planning: %s no longer exists", planned.Path)
		}
		if planned.Recognized != observed.Recognized || planned.Kind != observed.Kind ||
			planned.SHA256 != observed.SHA256 || planned.SymlinkTarget != observed.SymlinkTarget ||
			planned.Size != observed.Size || planned.Mode != observed.Mode || planned.UID != observed.UID ||
			planned.GID != observed.GID || planned.ModifiedUnixNano != observed.ModifiedUnixNano || planned.Details != observed.Details {
			return nil, fmt.Errorf("cleanup target changed after planning: %s", planned.Path)
		}
		validated = append(validated, observed)
	}
	return validated, nil
}

// samePublicRule prevents a reviewed plan from changing any explanatory or
// recognition field while retaining a valid rule identifier and path.
func samePublicRule(planned, compiled Rule) bool {
	if planned.ID != compiled.ID || planned.Feature != compiled.Feature || planned.Path != compiled.Path ||
		planned.Reason != compiled.Reason || planned.SymlinkTarget != compiled.SymlinkTarget ||
		len(planned.Markers) != len(compiled.Markers) {
		return false
	}
	for index := range planned.Markers {
		if planned.Markers[index] != compiled.Markers[index] {
			return false
		}
	}
	return true
}
