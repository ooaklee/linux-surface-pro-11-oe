package quality

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// namedMigrationDocuments is the closed set of dated reports whose maintained
// operator path must remain connected to linux-armer.
var namedMigrationDocuments = []string{
	"docs/hardware-report-20260613.md",
	"docs/installed-audio-speaker-wsa2-test-20260615.md",
	"docs/installed-bluetooth-public-address-test-20260614.md",
	"docs/installed-nvme-boot-test-20260613.md",
	"docs/installed-wifi-clean-flow-test-20260614.md",
	"docs/installed-wifi-patched-rfkill-test-20260614.md",
	"docs/installed-wifi-rfkill-test-20260613.md",
	"docs/installed-wifi-rfkill-upgrade-test-20260613.md",
	"docs/installed-wifi-windows-firmware-cold-boot-test-20260613.md",
	"docs/live-usb-test-20260613.md",
}

// currentOperatorDocuments are the maintained entry points that must never
// regain executable references to the retired root script directory.
var currentOperatorDocuments = []string{
	"README.md",
	"cli/linux-armer/README.md",
}

// retiredScriptReferencePattern recognises both dotted and undotted root
// script paths in prose or commands while leaving unrelated kernel paths alone.
var retiredScriptReferencePattern = regexp.MustCompile("(?:^|[\\s`\"'])(?:\\./)?scripts/[A-Za-z0-9]")

// immutableHistoricalNotice is mandatory on every named dated report because
// those evidence records deliberately retain retired commands and observations.
const immutableHistoricalNotice = "Immutable historical evidence — not a current procedure"

// TestMaintainedDocumentationReferencesCLI prevents maintained guides and the
// migration's named reports from losing their current native operator path.
func TestMaintainedDocumentationReferencesCLI(t *testing.T) {
	repositoryRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	paths, err := maintainedDocumentationPaths(repositoryRoot)
	if err != nil {
		t.Fatal(err)
	}
	for _, relative := range paths {
		content, err := os.ReadFile(filepath.Join(repositoryRoot, filepath.FromSlash(relative)))
		if err != nil {
			t.Errorf("read maintained documentation %s: %v", relative, err)
			continue
		}
		if !bytes.Contains(content, []byte("linux-armer")) {
			t.Errorf("maintained documentation %s has no linux-armer operator path", relative)
		}
		currentEntryPoint := containsDocument(currentOperatorDocuments, relative)
		if !currentEntryPoint && !bytes.Contains(content, []byte("Last reviewed:")) {
			t.Errorf("maintained documentation %s has no review date", relative)
		}
		if (currentEntryPoint || strings.HasPrefix(relative, "docs/how-to/")) && retiredScriptReferencePattern.Match(content) {
			t.Errorf("maintained operator documentation %s references the retired repository script directory", relative)
		}
		if containsDocument(namedMigrationDocuments, relative) && !bytes.Contains(content, []byte(immutableHistoricalNotice)) {
			t.Errorf("named historical report %s lacks its non-procedural safety notice", relative)
		}
	}
}

// maintainedDocumentationPaths returns every concrete how-to plus the closed
// named report set in deterministic repository-relative order.
func maintainedDocumentationPaths(repositoryRoot string) ([]string, error) {
	howToRoot := filepath.Join(repositoryRoot, "docs", "how-to")
	entries, err := os.ReadDir(howToRoot)
	if err != nil {
		return nil, fmt.Errorf("read maintained how-to directory: %w", err)
	}
	paths := append([]string(nil), currentOperatorDocuments...)
	paths = append(paths, namedMigrationDocuments...)
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || filepath.Ext(name) != ".md" || strings.HasPrefix(name, "_") {
			continue
		}
		paths = append(paths, filepath.ToSlash(filepath.Join("docs", "how-to", name)))
	}
	sort.Strings(paths)
	return paths, nil
}

// containsDocument reports whether a repository-relative path belongs to one
// small compiled documentation set.
func containsDocument(documents []string, candidate string) bool {
	for _, document := range documents {
		if document == candidate {
			return true
		}
	}
	return false
}

// TestRetiredScriptReferencePattern pins dotted, undotted, and command-prefixed
// repository-script detection without matching a kernel source scripts path.
func TestRetiredScriptReferencePattern(t *testing.T) {
	for _, candidate := range []string{
		"./scripts/retired.sh",
		"scripts/retired.sh",
		"bash scripts/retired.sh",
		"Run `scripts/retired.sh` now.",
	} {
		if !retiredScriptReferencePattern.MatchString(candidate) {
			t.Errorf("retired script reference was not recognised: %q", candidate)
		}
	}
	if retiredScriptReferencePattern.MatchString("/lib/modules/current/build/scripts/sign-file") {
		t.Fatal("kernel source scripts path was mistaken for the retired repository directory")
	}
}

// TestLegacyDiagnosticOutputRemainsIgnored prevents generator retirement from
// making identifier-bearing captures visible to an ordinary repository add.
func TestLegacyDiagnosticOutputRemainsIgnored(t *testing.T) {
	repositoryRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(filepath.Join(repositoryRoot, ".gitignore"))
	if err != nil {
		t.Fatal(err)
	}
	lines := make(map[string]bool)
	for _, line := range strings.Split(string(content), "\n") {
		lines[strings.TrimSpace(line)] = true
	}
	for _, required := range []string{"sp11-linux-checks/", "sp11-linux-checks-*.zip", "report-*/"} {
		if !lines[required] {
			t.Errorf(".gitignore omits private legacy diagnostic pattern %q", required)
		}
	}
}

// TestLegacyDiagnosticWorkflowCannotSkipGuard proves every retired private
// output shape triggers the workflow that rejects its tracked form.
func TestLegacyDiagnosticWorkflowCannotSkipGuard(t *testing.T) {
	repositoryRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(filepath.Join(repositoryRoot, ".github", "workflows", "linux-armer.yml"))
	if err != nil {
		t.Fatal(err)
	}
	for _, pattern := range []string{"**/sp11-linux-checks/**", "**/sp11-linux-checks-*.zip", "**/report-*/**"} {
		trigger := []byte(`- "` + pattern + `"`)
		if count := bytes.Count(content, trigger); count != 2 {
			t.Errorf("workflow contains %d trigger entries for %q, want pull request and push entries", count, pattern)
		}
		guard := []byte("':(glob)" + pattern + "'")
		if count := bytes.Count(content, guard); count != 1 {
			t.Errorf("workflow contains %d tracked-output guards for %q, want one", count, pattern)
		}
	}
}
