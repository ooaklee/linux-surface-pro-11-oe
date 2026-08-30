// Package cleanup detects and reversibly removes obsolete SP11 workarounds.
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

type Rule struct {
	ID      string
	Feature string
	Path    string
	Reason  string
	Markers []string
}

var LegacyRules = []Rule{
	{ID: "audio-wsa-unit", Feature: "audio", Path: "etc/systemd/system/sp11-wsa-routing.service", Reason: "legacy WSA routing is superseded by the native FullIO topology and UCM", Markers: []string{"sp11-enable-wsa-routing"}},
	{ID: "audio-wsa-enablement", Feature: "audio", Path: "etc/systemd/system/multi-user.target.wants/sp11-wsa-routing.service", Reason: "legacy WSA routing enablement is obsolete"},
	{ID: "audio-wsa-helper", Feature: "audio", Path: "usr/local/sbin/sp11-enable-wsa-routing.sh", Reason: "legacy WSA routing is superseded", Markers: []string{"sp11-wsa-routing"}},
	{ID: "audio-wsa-helper-old", Feature: "audio", Path: "usr/local/sbin/sp11-enable-wsa-routing", Reason: "legacy WSA routing is superseded", Markers: []string{"sp11"}},
	{ID: "audio-manual-sink", Feature: "audio", Path: "etc/pipewire/pipewire.conf.d/50-sp11-speakers.conf", Reason: "manual PipeWire sinks conflict with current native audio routing", Markers: []string{"sp11"}},
	{ID: "audio-boot-race-helper", Feature: "audio", Path: "usr/local/sbin/sp11-fix-audio-boot-race", Reason: "legacy boot-race restarts are obsolete", Markers: []string{"sp11-wsa-routing"}},
	{ID: "touch-modprobe", Feature: "touchscreen", Path: "etc/modprobe.d/sp11-touchscreen.conf", Reason: "the current kernel contains the touchscreen driver in-tree", Markers: []string{"mshw0485_touch"}},
	{ID: "touch-modules-load", Feature: "touchscreen", Path: "etc/modules-load.d/sp11-touchscreen.conf", Reason: "the current kernel contains the touchscreen driver in-tree", Markers: []string{"mshw0485_touch"}},
	{ID: "touch-initramfs-hook", Feature: "touchscreen", Path: "etc/initramfs-tools/hooks/sp11-touchscreen", Reason: "the current kernel contains the touchscreen driver in-tree", Markers: []string{"mshw0485_touch"}},
	{ID: "touch-dracut", Feature: "touchscreen", Path: "etc/dracut.conf.d/91-sp11-touchscreen.conf", Reason: "the current kernel contains the touchscreen driver in-tree", Markers: []string{"mshw0485_touch"}},
	{ID: "pen-g6-unit", Feature: "pen", Path: "etc/systemd/system/g6-pen.service", Reason: "production stylus input now uses the paired iptsd integration", Markers: []string{"g6-pen"}},
	{ID: "pen-g6-enablement", Feature: "pen", Path: "etc/systemd/system/multi-user.target.wants/g6-pen.service", Reason: "production stylus input now uses the paired iptsd integration"},
}

type Finding struct {
	Rule       Rule   `json:"rule"`
	Path       string `json:"path"`
	SHA256     string `json:"sha256,omitempty"`
	Kind       string `json:"kind"`
	Recognized bool   `json:"recognized"`
	Details    string `json:"details"`
}

type ScanReport struct {
	Root     string    `json:"root"`
	Findings []Finding `json:"findings"`
}

type Receipt struct {
	CreatedAt time.Time     `json:"created_at"`
	Root      string        `json:"root"`
	Backup    string        `json:"backup"`
	Changes   []ReceiptItem `json:"changes"`
}

type ReceiptItem struct {
	RuleID     string `json:"rule_id"`
	Original   string `json:"original"`
	BackupPath string `json:"backup_path"`
	SHA256     string `json:"sha256,omitempty"`
}

func Scan(root string) (ScanReport, error) {
	absolute, err := filepath.Abs(root)
	if err != nil {
		return ScanReport{}, err
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return ScanReport{}, fmt.Errorf("resolve cleanup root: %w", err)
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
		finding := Finding{Rule: rule, Path: path, Recognized: true, Details: rule.Reason}
		if info.Mode()&os.ModeSymlink != 0 {
			finding.Kind = "symlink"
			target, readErr := os.Readlink(path)
			if readErr != nil {
				return ScanReport{}, readErr
			}
			finding.Details += "; target=" + target
		} else if info.Mode().IsRegular() {
			finding.Kind = "file"
			data, readErr := os.ReadFile(path)
			if readErr != nil {
				return ScanReport{}, readErr
			}
			digest := sha256.Sum256(data)
			finding.SHA256 = hex.EncodeToString(digest[:])
			for _, marker := range rule.Markers {
				if !strings.Contains(string(data), marker) {
					finding.Recognized = false
					finding.Details = "path matches a legacy workaround, but content marker is absent; manual review required"
					break
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

// Apply backs up and removes recognized findings. Unrecognized content is never removed.
func Apply(report ScanReport, yes bool) (Receipt, error) {
	if !yes {
		return Receipt{}, errors.New("cleanup apply requires --yes after reviewing clean plan")
	}
	validatedFindings, err := revalidateFindings(report)
	if err != nil {
		return Receipt{}, err
	}
	report.Findings = validatedFindings
	if len(report.Findings) == 0 {
		return Receipt{CreatedAt: time.Now().UTC(), Root: report.Root}, nil
	}
	stamp := time.Now().UTC().Format("20060102T150405Z")
	backup, err := safeJoin(report.Root, filepath.Join("var/lib/linux-armer/backups", stamp))
	if err != nil {
		return Receipt{}, err
	}
	if err := os.MkdirAll(backup, 0o700); err != nil {
		return Receipt{}, fmt.Errorf("create cleanup backup: %w", err)
	}
	receipt := Receipt{CreatedAt: time.Now().UTC(), Root: report.Root, Backup: backup}
	for _, finding := range report.Findings {
		if !finding.Recognized {
			continue
		}
		relative, err := filepath.Rel(report.Root, finding.Path)
		if err != nil || strings.HasPrefix(relative, "..") {
			return Receipt{}, fmt.Errorf("unsafe cleanup path %s", finding.Path)
		}
		backupPath := filepath.Join(backup, relative)
		if err := os.MkdirAll(filepath.Dir(backupPath), 0o700); err != nil {
			return Receipt{}, err
		}
		if err := copyEntry(finding.Path, backupPath); err != nil {
			return Receipt{}, fmt.Errorf("back up %s: %w", finding.Path, err)
		}
		if err := os.Remove(finding.Path); err != nil {
			return Receipt{}, fmt.Errorf("remove %s: %w", finding.Path, err)
		}
		receipt.Changes = append(receipt.Changes, ReceiptItem{
			RuleID: finding.Rule.ID, Original: finding.Path, BackupPath: backupPath, SHA256: finding.SHA256,
		})
	}
	receiptPath := filepath.Join(backup, "receipt.json")
	if err := writeJSON(receiptPath, receipt); err != nil {
		return Receipt{}, err
	}
	return receipt, nil
}

func WriteJSON(w io.Writer, value any) error {
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

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

func withinRoot(root, path string) bool {
	relative, err := filepath.Rel(root, path)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

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
			planned.SHA256 != observed.SHA256 || planned.Details != observed.Details {
			return nil, fmt.Errorf("cleanup target changed after planning: %s", planned.Path)
		}
		validated = append(validated, observed)
	}
	return validated, nil
}

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
	closeErr := out.Close()
	return errors.Join(copyErr, closeErr)
}

func writeJSON(path string, value any) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	encodeErr := WriteJSON(file, value)
	closeErr := file.Close()
	return errors.Join(encodeErr, closeErr)
}
