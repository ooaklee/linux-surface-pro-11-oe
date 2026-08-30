package status

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// audioFeedbackBootArgument is required on every boot by the FullIO topology.
const audioFeedbackBootArgument = "soundwire_qcom.sp11_feedback_active_offset2_zero=1"

// audioFeedbackBootPrefix identifies an explicit but incorrect value for the
// required kernel parameter.
const audioFeedbackBootPrefix = "soundwire_qcom.sp11_feedback_active_offset2_zero="

// maxBootConfigurationBytes bounds static inspection of each GRUB text file.
const maxBootConfigurationBytes = 4 << 20

// bootConfigurationKind selects the conservative line syntax accepted for a
// GRUB defaults file or a generated GRUB configuration.
type bootConfigurationKind uint8

// Boot configuration kinds prevent unrelated prose from satisfying the
// required audio kernel argument.
const (
	grubDefaults bootConfigurationKind = iota
	generatedGRUB
)

// bootConfiguration identifies one target-root GRUB file and how its lines
// should be interpreted.
type bootConfiguration struct {
	logicalPath string
	kind        bootConfigurationKind
}

// inspectAudioBootArgument searches GRUB defaults and generated configurations
// without executing bootloader tooling or reading outside the selected root.
func inspectAudioBootArgument(fs *rootedFS, required bool) (Check, error) {
	configurations, err := discoverBootConfigurations(fs)
	if err != nil {
		return Check{}, err
	}
	inspected := make([]string, 0, len(configurations))
	incorrect := make([]string, 0)
	for _, configuration := range configurations {
		found, wrongValue, present, err := inspectBootConfiguration(fs, configuration)
		if err != nil {
			return Check{}, err
		}
		if !present {
			continue
		}
		inspected = append(inspected, "/"+filepath.ToSlash(configuration.logicalPath))
		if wrongValue {
			incorrect = append(incorrect, "/"+filepath.ToSlash(configuration.logicalPath))
		}
		if found {
			return Check{
				ID:       "audio-fullio-boot-argument",
				Feature:  FeatureAudio,
				State:    StatePass,
				Required: required,
				Detail:   audioFeedbackBootArgument + " is configured in /" + filepath.ToSlash(configuration.logicalPath),
			}, nil
		}
	}
	detail := audioFeedbackBootArgument + " is not configured"
	if len(incorrect) != 0 {
		detail += "; a different value is present in " + strings.Join(incorrect, ", ")
	} else if len(inspected) != 0 {
		detail += " in " + strings.Join(inspected, ", ")
	} else {
		detail += "; no GRUB defaults or generated grub.cfg was available"
	}
	return Check{
		ID:          "audio-fullio-boot-argument",
		Feature:     FeatureAudio,
		State:       optionalState(required),
		Required:    required,
		Detail:      detail,
		Remediation: "add " + audioFeedbackBootArgument + " to the persistent GRUB kernel command line and regenerate grub.cfg",
	}, nil
}

// discoverBootConfigurations returns deterministic candidate paths, including
// drop-ins below the target root, while ignoring absent optional directories.
func discoverBootConfigurations(fs *rootedFS) ([]bootConfiguration, error) {
	configurations := []bootConfiguration{
		{logicalPath: "etc/default/grub", kind: grubDefaults},
		{logicalPath: "boot/grub/grub.cfg", kind: generatedGRUB},
		{logicalPath: "boot/grub2/grub.cfg", kind: generatedGRUB},
	}
	directory, err := fs.resolve("etc/default/grub.d", true)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(directory)
	if err != nil && !missing(err) {
		return nil, fmt.Errorf("read target-root GRUB defaults directory: %w", err)
	}
	if err == nil {
		names := make([]string, 0, len(entries))
		for _, entry := range entries {
			if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".cfg") {
				names = append(names, entry.Name())
			}
		}
		sort.Strings(names)
		for _, name := range names {
			configurations = append(configurations, bootConfiguration{
				logicalPath: filepath.Join("etc/default/grub.d", name),
				kind:        grubDefaults,
			})
		}
	}
	return configurations, nil
}

// inspectBootConfiguration checks one bounded text file for an exact argument
// in a recognised GRUB assignment or generated Linux command line.
func inspectBootConfiguration(fs *rootedFS, configuration bootConfiguration) (found, wrongValue, present bool, err error) {
	path, info, err := fs.regular(configuration.logicalPath, true)
	if missing(err) {
		return false, false, false, nil
	}
	if err != nil {
		return false, false, false, fmt.Errorf("inspect target-root boot configuration /%s: %w", filepath.ToSlash(configuration.logicalPath), err)
	}
	if info.Size() > maxBootConfigurationBytes {
		return false, false, true, fmt.Errorf("target-root boot configuration /%s exceeds %d bytes", filepath.ToSlash(configuration.logicalPath), maxBootConfigurationBytes)
	}
	file, err := os.Open(path)
	if err != nil {
		return false, false, true, fmt.Errorf("open target-root boot configuration /%s: %w", filepath.ToSlash(configuration.logicalPath), err)
	}
	defer file.Close()
	return scanBootConfiguration(io.LimitReader(file, maxBootConfigurationBytes+1), configuration.kind)
}

// scanBootConfiguration accepts only GRUB command-line assignments or generated
// Linux boot commands and reports exact and conflicting argument values.
func scanBootConfiguration(reader io.Reader, kind bootConfigurationKind) (found, wrongValue, present bool, err error) {
	data, err := io.ReadAll(reader)
	if err != nil {
		return false, false, true, err
	}
	if len(data) > maxBootConfigurationBytes {
		return false, false, true, fmt.Errorf("boot configuration exceeds %d bytes", maxBootConfigurationBytes)
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if comment := strings.IndexByte(line, '#'); comment >= 0 {
			line = strings.TrimSpace(line[:comment])
		}
		if !eligibleBootLine(line, kind) {
			continue
		}
		for _, token := range bootLineTokens(line) {
			if token == audioFeedbackBootArgument {
				found = true
			}
			if strings.HasPrefix(token, audioFeedbackBootPrefix) && token != audioFeedbackBootArgument {
				wrongValue = true
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return false, false, true, err
	}
	return found, wrongValue, true, nil
}

// eligibleBootLine prevents comments, arbitrary prose, and unrelated variables
// from satisfying the audio argument requirement.
func eligibleBootLine(line string, kind bootConfigurationKind) bool {
	if kind == grubDefaults {
		name, _, found := strings.Cut(line, "=")
		if !found {
			return false
		}
		name = strings.TrimSpace(name)
		return name == "GRUB_CMDLINE_LINUX" || name == "GRUB_CMDLINE_LINUX_DEFAULT"
	}
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return false
	}
	command := strings.TrimSpace(fields[0])
	return command == "linux" || command == "linuxefi" || command == "linux16"
}

// bootLineTokens splits shell-like quoting and whitespace sufficiently for an
// exact key-value argument without interpreting or expanding the configuration.
func bootLineTokens(line string) []string {
	return strings.FieldsFunc(line, func(character rune) bool {
		switch character {
		case ' ', '\t', '\r', '\n', '\'', '"':
			return true
		default:
			return false
		}
	})
}
