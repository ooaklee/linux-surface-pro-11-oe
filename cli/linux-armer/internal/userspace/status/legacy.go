package status

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// maxLegacyDirectoryEntries bounds diagnostic scans of target-root module and
// release-marker directories.
const maxLegacyDirectoryEntries = 256

// inspectG6PenStatus reports whether diagnostic-only G6 tooling is absent,
// safely installed but disabled, or statically enabled in conflict with IPTSD.
func inspectG6PenStatus(fs *rootedFS) (Check, error) {
	found := make(map[string]bool)
	for _, logicalPath := range append(append([]string(nil), g6PenPaths...), g6PenEnabledPath) {
		_, _, err := fs.lstat(logicalPath)
		if missing(err) {
			continue
		}
		if err != nil {
			return Check{}, err
		}
		found["/"+filepath.ToSlash(logicalPath)] = true
	}
	if len(found) == 0 {
		return Check{ID: "g6-pen-diagnostic", Feature: FeatureG6Pen, State: StateSkip, Detail: "diagnostic-only g6-pen tooling is not installed"}, nil
	}
	if found["/"+filepath.ToSlash(g6PenEnabledPath)] {
		return Check{
			ID:          "g6-pen-diagnostic",
			Feature:     FeatureG6Pen,
			State:       StateWarn,
			Detail:      "diagnostic-only g6-pen.service is statically enabled: " + strings.Join(sortedKeys(found), ", "),
			Remediation: "disable g6-pen.service and keep it stopped except during controlled capture or replay",
		}, nil
	}
	return Check{
		ID:      "g6-pen-diagnostic",
		Feature: FeatureG6Pen,
		State:   StatePass,
		Detail:  "diagnostic-only g6-pen files are installed but not statically enabled: " + strings.Join(sortedKeys(found), ", "),
	}, nil
}

// inspectObsoleteTouchscreen reports fixed integration, release markers, and
// exact updates-tree modules left by the retired out-of-tree workflow.
func inspectObsoleteTouchscreen(fs *rootedFS) (Check, error) {
	found := make(map[string]bool)
	for _, logicalPath := range obsoleteTouchscreenPaths {
		_, _, err := fs.lstat(logicalPath)
		if missing(err) {
			continue
		}
		if err != nil {
			return Check{}, err
		}
		found["/"+filepath.ToSlash(logicalPath)] = true
	}
	if err := inspectLegacyReleaseMarkers(fs, found); err != nil {
		return Check{}, err
	}
	if err := inspectLegacyModuleTrees(fs, found); err != nil {
		return Check{}, err
	}
	if len(found) == 0 {
		return Check{
			ID:      "oot-touchscreen-remnants",
			Feature: FeatureTouch,
			State:   StatePass,
			Detail:  "no recognised out-of-tree touchscreen integration remnants were found",
		}, nil
	}
	return Check{
		ID:          "oot-touchscreen-remnants",
		Feature:     FeatureTouch,
		State:       StateWarn,
		Detail:      "obsolete out-of-tree touchscreen remnants were found: " + strings.Join(sortedKeys(found), ", "),
		Remediation: "use linux-armer clean only for recognised fixed configuration hooks; manually review reported module overrides and release markers, then rebuild each affected initramfs",
	}, nil
}

// inspectLegacyReleaseMarkers adds bounded release-marker entries from the
// retired installer's target-root state directory.
func inspectLegacyReleaseMarkers(fs *rootedFS, found map[string]bool) error {
	const logicalDirectory = "etc/sp11-touchscreen/releases"
	directory, err := fs.resolve(logicalDirectory, true)
	if err != nil {
		return err
	}
	entries, err := os.ReadDir(directory)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read obsolete touchscreen release markers: %w", err)
	}
	if len(entries) > maxLegacyDirectoryEntries {
		return fmt.Errorf("obsolete touchscreen release-marker directory exceeds %d entries", maxLegacyDirectoryEntries)
	}
	for _, entry := range entries {
		found["/"+filepath.ToSlash(filepath.Join(logicalDirectory, entry.Name()))] = true
	}
	return nil
}

// inspectLegacyModuleTrees finds only the exact updates-tree paths installed by
// the superseded touchscreen workflow and never interprets module contents.
func inspectLegacyModuleTrees(fs *rootedFS, found map[string]bool) error {
	const logicalModules = "lib/modules"
	directory, err := fs.resolve(logicalModules, true)
	if err != nil {
		return err
	}
	entries, err := os.ReadDir(directory)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read target-root module trees for obsolete touchscreen support: %w", err)
	}
	if len(entries) > maxLegacyDirectoryEntries {
		return fmt.Errorf("target-root module directory exceeds %d entries during obsolete touchscreen inspection", maxLegacyDirectoryEntries)
	}
	sort.Slice(entries, func(left, right int) bool { return entries[left].Name() < entries[right].Name() })
	for _, entry := range entries {
		abi := entry.Name()
		if validateABI(abi) != nil || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return fmt.Errorf("inspect target-root module tree %s: %w", abi, err)
		}
		if !info.IsDir() {
			continue
		}
		for _, modulePath := range obsoleteTouchscreenModulePaths {
			for _, suffix := range []string{"", ".xz", ".zst"} {
				logicalPath := filepath.Join(logicalModules, abi, modulePath+suffix)
				_, _, err := fs.lstat(logicalPath)
				if missing(err) {
					continue
				}
				if err != nil {
					return err
				}
				found["/"+filepath.ToSlash(logicalPath)] = true
			}
		}
	}
	return nil
}
