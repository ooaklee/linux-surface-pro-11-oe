package build

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	// maximumBaseBytes bounds parsing of the human-maintained source authority.
	maximumBaseBytes = 16 << 10
	// expectedUbuntuVersion is the only source version reviewed by this recipe.
	expectedUbuntuVersion = "0.7.0-1ubuntu2"
	// expectedUbuntuSeries is the first supported Ubuntu source series.
	expectedUbuntuSeries = "resolute"
)

// baseCommitExpression accepts a complete lowercase Git object identifier.
var baseCommitExpression = regexp.MustCompile(`^[0-9a-f]{40}$`)

// baseHashExpression accepts an exact lowercase SHA-256 value.
var baseHashExpression = regexp.MustCompile(`^[0-9a-f]{64}$`)

// baseDateExpression accepts the human-readable ISO calendar date in BASE.txt.
var baseDateExpression = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`)

// baseFields is the exact, ordered BASE.txt field contract.
var baseFields = []string{
	"Upstream project",
	"Upstream tag",
	"Upstream commit",
	"Ubuntu package validated on device",
	"Ubuntu DSC SHA-256",
	"Ubuntu orig tarball SHA-256",
	"Ubuntu Debian tarball SHA-256",
	"Patch validation",
	"IPA validation",
	"Turbine userspace source",
	"Validation date",
}

// Base describes the strictly parsed source and validation authority.
type Base struct {
	// UpstreamProject is the canonical upstream repository URL.
	UpstreamProject string
	// UpstreamTag is the exact upstream release tag.
	UpstreamTag string
	// UpstreamCommit is the exact upstream source commit.
	UpstreamCommit string
	// UbuntuVersion is the exact Debian source version.
	UbuntuVersion string
	// UbuntuSeries is the exact Ubuntu series named by the authority.
	UbuntuSeries string
	// DSCSHA256 authenticates the Debian source control file.
	DSCSHA256 string
	// OrigSHA256 authenticates the upstream source tarball.
	OrigSHA256 string
	// DebianSHA256 authenticates the Debian packaging tarball.
	DebianSHA256 string
	// PatchValidation records the human-reviewed patch applicability statement.
	PatchValidation string
	// IPAValidation records the human-reviewed package validation statement.
	IPAValidation string
	// TurbineSource records the downstream derivation reference.
	TurbineSource string
	// ValidationDate is the recorded review date.
	ValidationDate string
}

// ParseBase parses the exact human-readable BASE.txt contract without accepting
// duplicate, reordered, unknown, control-bearing, or bidirectional text.
func ParseBase(data []byte) (Base, error) {
	if len(data) == 0 || len(data) > maximumBaseBytes {
		return Base{}, errors.New("BASE.txt size is outside the compiled limit")
	}
	if !utf8.Valid(data) || bytes.ContainsRune(data, '\r') {
		return Base{}, errors.New("BASE.txt must contain valid canonical UTF-8 lines")
	}
	for _, character := range string(data) {
		if forbiddenBaseRune(character) {
			return Base{}, fmt.Errorf("BASE.txt contains forbidden control or bidirectional text U+%04X", character)
		}
	}

	values := make(map[string]string, len(baseFields))
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 1024), maximumBaseBytes)
	line := 0
	for scanner.Scan() {
		line++
		text := scanner.Text()
		if text == "" {
			return Base{}, fmt.Errorf("BASE.txt line %d is unexpectedly blank", line)
		}
		separator := strings.Index(text, ": ")
		if separator <= 0 || separator+2 >= len(text) {
			return Base{}, fmt.Errorf("BASE.txt line %d is not a label and value", line)
		}
		label, value := text[:separator], text[separator+2:]
		if line > len(baseFields) || label != baseFields[line-1] {
			return Base{}, fmt.Errorf("BASE.txt line %d must be %q", line, expectedBaseLabel(line))
		}
		if _, duplicate := values[label]; duplicate {
			return Base{}, fmt.Errorf("BASE.txt repeats %q", label)
		}
		if strings.TrimSpace(value) != value {
			return Base{}, fmt.Errorf("BASE.txt %q has surrounding whitespace", label)
		}
		values[label] = value
	}
	if err := scanner.Err(); err != nil {
		return Base{}, fmt.Errorf("read BASE.txt: %w", err)
	}
	if line != len(baseFields) {
		return Base{}, fmt.Errorf("BASE.txt has %d fields, want %d", line, len(baseFields))
	}

	version, series, err := parseUbuntuAuthority(values["Ubuntu package validated on device"])
	if err != nil {
		return Base{}, err
	}
	base := Base{
		UpstreamProject: values["Upstream project"],
		UpstreamTag:     values["Upstream tag"],
		UpstreamCommit:  values["Upstream commit"],
		UbuntuVersion:   version,
		UbuntuSeries:    series,
		DSCSHA256:       values["Ubuntu DSC SHA-256"],
		OrigSHA256:      values["Ubuntu orig tarball SHA-256"],
		DebianSHA256:    values["Ubuntu Debian tarball SHA-256"],
		PatchValidation: values["Patch validation"],
		IPAValidation:   values["IPA validation"],
		TurbineSource:   values["Turbine userspace source"],
		ValidationDate:  values["Validation date"],
	}
	if err := validateBase(base); err != nil {
		return Base{}, err
	}
	return base, nil
}

// expectedBaseLabel returns a bounded diagnostic for a missing or extra line.
func expectedBaseLabel(line int) string {
	if line >= 1 && line <= len(baseFields) {
		return baseFields[line-1]
	}
	return "end of file"
}

// parseUbuntuAuthority extracts the exact version and series tuple.
func parseUbuntuAuthority(value string) (string, string, error) {
	const prefix = expectedUbuntuVersion + " (arm64, "
	if !strings.HasPrefix(value, prefix) || !strings.HasSuffix(value, ")") {
		return "", "", fmt.Errorf("unexpected Ubuntu package authority %q", value)
	}
	series := strings.TrimSuffix(strings.TrimPrefix(value, prefix), ")")
	if series != expectedUbuntuSeries {
		return "", "", fmt.Errorf("unexpected Ubuntu source series %q", series)
	}
	return expectedUbuntuVersion, series, nil
}

// validateBase applies the fixed source identity and digest policy.
func validateBase(base Base) error {
	if base.UpstreamProject != "https://git.libcamera.org/libcamera/libcamera.git" {
		return fmt.Errorf("unexpected upstream project %q", base.UpstreamProject)
	}
	if base.UpstreamTag != "v0.7.0" || !baseCommitExpression.MatchString(base.UpstreamCommit) {
		return errors.New("BASE.txt contains an invalid upstream tag or commit")
	}
	for label, digest := range map[string]string{
		"Ubuntu DSC":            base.DSCSHA256,
		"Ubuntu orig tarball":   base.OrigSHA256,
		"Ubuntu Debian tarball": base.DebianSHA256,
	} {
		if !baseHashExpression.MatchString(digest) {
			return fmt.Errorf("%s SHA-256 is malformed", label)
		}
	}
	if base.PatchValidation == "" || base.IPAValidation == "" || base.TurbineSource == "" {
		return errors.New("BASE.txt validation and derivation fields must not be empty")
	}
	if !baseDateExpression.MatchString(base.ValidationDate) {
		return fmt.Errorf("BASE.txt validation date is malformed: %q", base.ValidationDate)
	}
	return nil
}

// forbiddenBaseRune rejects terminal controls and Unicode direction overrides.
func forbiddenBaseRune(character rune) bool {
	if character == '\n' || character == '\t' {
		return false
	}
	if unicode.IsControl(character) {
		return true
	}
	return character == '\u061c' || character == '\u200e' || character == '\u200f' ||
		(character >= '\u202a' && character <= '\u202e') ||
		(character >= '\u2066' && character <= '\u2069')
}
