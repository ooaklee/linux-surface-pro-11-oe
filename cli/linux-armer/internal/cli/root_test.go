package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/catalog"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/cleanup"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/plan"
)

// TestRootNoArgumentsOnNonTerminalPrintsHelp verifies that a non-interactive
// invocation with no arguments prints useful command help and exits cleanly.
func TestRootNoArgumentsOnNonTerminalPrintsHelp(t *testing.T) {
	t.Parallel()

	output, errorOutput, err := executeCLI(t)
	if err != nil {
		t.Fatalf("ExecuteContext() error = %v", err)
	}
	if errorOutput != "" {
		t.Fatalf("stderr = %q, want empty", errorOutput)
	}
	for _, text := range []string{
		"linux-armer builds and validates experimental ARM64 installation media",
		"Usage:",
		"linux-armer [flags]",
		"Available Commands:",
		"catalog",
		"image",
		"kernel",
		"userspace",
		"handoff",
		"wizard",
	} {
		if !strings.Contains(output, text) {
			t.Errorf("help output does not contain %q:\n%s", text, output)
		}
	}
}

// TestUserspaceCatalogDelivery verifies that userspace catalogue commands expose
// the complete catalogue consistently in human-readable and JSON forms.
func TestUserspaceCatalogDelivery(t *testing.T) {
	t.Parallel()

	t.Run("list is complete and exposes bounded actions", func(t *testing.T) {
		t.Parallel()
		output, errorOutput, err := executeCLI(t, "userspace", "list")
		if err != nil {
			t.Fatalf("userspace list error = %v", err)
		}
		if errorOutput != "" {
			t.Fatalf("stderr = %q", errorOutput)
		}
		for _, text := range []string{
			"ID", "LEVEL", "CAPABILITY", "ACTIONS",
			"audio-fullio-v19c", "status,pull,install",
			"iptsd-v1", "status,pull,build,install",
			"oot-touchscreen", "obsolete",
		} {
			if !strings.Contains(output, text) {
				t.Errorf("userspace list does not contain %q:\n%s", text, output)
			}
		}
	})

	t.Run("JSON is machine readable", func(t *testing.T) {
		t.Parallel()
		output, _, err := executeCLI(t, "userspace", "list", "--json")
		if err != nil {
			t.Fatalf("userspace list --json error = %v", err)
		}
		var components []map[string]any
		if err := json.Unmarshal([]byte(output), &components); err != nil {
			t.Fatalf("userspace JSON cannot be decoded: %v\n%s", err, output)
		}
		if len(components) != 9 {
			t.Fatalf("userspace components = %d, want 9", len(components))
		}
	})

	t.Run("catalog validation uses dedicated strict loader", func(t *testing.T) {
		t.Parallel()
		output, _, err := executeCLI(t, "userspace", "catalog", "validate")
		if err != nil {
			t.Fatalf("userspace catalog validate error = %v", err)
		}
		if output != "userspace catalog valid: schema 2, 9 components\n" {
			t.Fatalf("output = %q", output)
		}
	})

	t.Run("aliases resolve for show", func(t *testing.T) {
		t.Parallel()
		output, _, err := executeCLI(t, "userspace", "show", "audio")
		if err != nil {
			t.Fatalf("userspace show audio error = %v", err)
		}
		if !strings.Contains(output, "FullIO v19c Audio") || !strings.Contains(output, "actions: status,pull,install") {
			t.Fatalf("unexpected userspace show output:\n%s", output)
		}
	})
}

// TestDoctorUserspaceSharesStatusReport verifies that the doctor alias returns
// exactly the same structured assessment as userspace status.
func TestDoctorUserspaceSharesStatusReport(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	statusOutput, _, statusErr := executeCLI(t,
		"userspace", "status", "--root", root, "--feature", "power", "--json")
	if statusErr == nil {
		t.Fatal("userspace status unexpectedly accepted missing explicitly selected power support")
	}
	doctorOutput, _, doctorErr := executeCLI(t,
		"doctor", "userspace", "--root", root, "--feature", "power", "--json")
	if doctorErr == nil {
		t.Fatal("doctor userspace unexpectedly accepted missing explicitly selected power support")
	}
	if statusErr.Error() != doctorErr.Error() {
		t.Fatalf("shared errors differ: status %q, doctor %q", statusErr, doctorErr)
	}
	if statusOutput != doctorOutput {
		t.Fatalf("shared reports differ:\nstatus: %s\ndoctor: %s", statusOutput, doctorOutput)
	}
	var report struct {
		Ready bool `json:"ready"`
	}
	if err := json.Unmarshal([]byte(statusOutput), &report); err != nil {
		t.Fatal(err)
	}
	if report.Ready {
		t.Fatalf("explicitly selected power support should block readiness when absent: %s", statusOutput)
	}
}

// TestRootExplicitHelp verifies that the explicit help flag renders root usage.
func TestRootExplicitHelp(t *testing.T) {
	t.Parallel()

	output, _, err := executeCLI(t, "--help")
	if err != nil {
		t.Fatalf("ExecuteContext(--help) error = %v", err)
	}
	if !strings.Contains(output, "linux-armer [flags]") {
		t.Fatalf("help output = %q, want root usage", output)
	}
}

// TestCatalogListDelivery verifies deterministic image catalogue ordering and
// equivalent machine-readable list output.
func TestCatalogListDelivery(t *testing.T) {
	t.Parallel()

	t.Run("table is complete and deterministically ordered", func(t *testing.T) {
		t.Parallel()

		output, errorOutput, err := executeCLI(t, "catalog", "list")
		if err != nil {
			t.Fatalf("catalog list error = %v", err)
		}
		if errorOutput != "" {
			t.Fatalf("stderr = %q, want empty", errorOutput)
		}
		for _, header := range []string{"ID", "IMAGE", "FORMAT", "SUPPORT", "EXPERIMENTAL", "MUTABLE", "CHECKSUM"} {
			if !strings.Contains(output, header) {
				t.Fatalf("catalog table has no %s header:\n%s", header, output)
			}
		}
		if !strings.Contains(output, "ubuntu-concept-resolute-x1e") || !strings.Contains(output, "none") || !strings.Contains(output, "sha256") {
			t.Fatalf("catalog table does not expose checksum-pin states:\n%s", output)
		}
		orderedIDs := []string{
			"debian-13-6-0-dvd-1",
			"elementary-os-8-1-20260219",
			"fedora-workstation-44-raw",
			"fedora-workstation-live-44",
			"pop-os-24-04-arm64-generic-3",
			"ubuntu-concept-resolute-x1e",
		}
		previous := -1
		for _, id := range orderedIDs {
			index := strings.Index(output, id)
			if index < 0 {
				t.Errorf("catalog table is missing %q:\n%s", id, output)
			}
			if index <= previous {
				t.Errorf("catalog ID %q is not after its predecessor:\n%s", id, output)
			}
			previous = index
		}
	})

	t.Run("JSON is machine readable", func(t *testing.T) {
		t.Parallel()

		output, _, err := executeCLI(t, "catalog", "list", "--json")
		if err != nil {
			t.Fatalf("catalog list --json error = %v", err)
		}
		var entries []catalog.Entry
		if err := json.Unmarshal([]byte(output), &entries); err != nil {
			t.Fatalf("catalog list JSON cannot be decoded: %v\n%s", err, output)
		}
		if len(entries) != 6 {
			t.Fatalf("catalog list JSON entries = %d, want 6", len(entries))
		}
		for index := 1; index < len(entries); index++ {
			if entries[index-1].ID >= entries[index].ID {
				t.Fatalf("catalog JSON is not ordered by ID at %q and %q", entries[index-1].ID, entries[index].ID)
			}
		}
	})
}

// TestCatalogShowDelivery verifies detailed catalogue display, JSON output, and
// the error returned for an unknown image identifier.
func TestCatalogShowDelivery(t *testing.T) {
	t.Parallel()

	t.Run("implemented entry", func(t *testing.T) {
		t.Parallel()

		output, _, err := executeCLI(t, "catalog", "show", "ubuntu-concept-resolute-x1e")
		if err != nil {
			t.Fatalf("catalog show error = %v", err)
		}
		for _, text := range []string{
			"Ubuntu Concept Resolute Desktop for X1E (2026-03-26)",
			"Filename: resolute-desktop-arm64+x1e-20260326.iso",
			"Architecture: arm64",
			"Support: implemented",
			"Adapter: ubuntu-casper",
			"Experimental: true",
			"Mutable: false",
			"Checksum: none (source bytes are not publisher-pinned)",
			"Canonical does not publish a checksum",
			"Notes:",
		} {
			if !strings.Contains(output, text) {
				t.Errorf("catalog show output does not contain %q:\n%s", text, output)
			}
		}
	})

	t.Run("pinned entry", func(t *testing.T) {
		t.Parallel()

		output, _, err := executeCLI(t, "catalog", "show", "fedora-workstation-44-raw")
		if err != nil {
			t.Fatalf("catalog show pinned entry error = %v", err)
		}
		for _, text := range []string{
			"Experimental: true", "Mutable: false",
			"Checksum: sha256:0361c13141e6f57e24d6ee5227066c33a45f7f92a95f41d0bbd343e4fd05da18",
		} {
			if !strings.Contains(output, text) {
				t.Errorf("catalog show pinned output does not contain %q:\n%s", text, output)
			}
		}
	})

	t.Run("JSON entry", func(t *testing.T) {
		t.Parallel()

		output, _, err := executeCLI(t, "catalog", "show", "fedora-workstation-44-raw", "--json")
		if err != nil {
			t.Fatalf("catalog show --json error = %v", err)
		}
		var entry catalog.Entry
		if err := json.Unmarshal([]byte(output), &entry); err != nil {
			t.Fatalf("catalog show JSON cannot be decoded: %v\n%s", err, output)
		}
		if entry.ID != "fedora-workstation-44-raw" || entry.ArtifactKind != catalog.ArtifactKindRawXZ || entry.SupportLevel != catalog.SupportLevelCatalogOnly {
			t.Fatalf("catalog show JSON entry = %#v", entry)
		}
	})

	t.Run("missing entry", func(t *testing.T) {
		t.Parallel()

		_, _, err := executeCLI(t, "catalog", "show", "missing-image")
		if err == nil || !strings.Contains(err.Error(), `catalog entry "missing-image" was not found`) {
			t.Fatalf("catalog show missing error = %v", err)
		}
	})
}

// TestCatalogValidateDelivery verifies embedded and override catalogue validation
// in both human-readable and structured output modes.
func TestCatalogValidateDelivery(t *testing.T) {
	t.Parallel()

	t.Run("embedded catalog", func(t *testing.T) {
		t.Parallel()

		output, _, err := executeCLI(t, "catalog", "validate")
		if err != nil {
			t.Fatalf("catalog validate error = %v", err)
		}
		if output != "catalog valid: schema 2, 6 entries\n" {
			t.Fatalf("catalog validate output = %q", output)
		}
	})

	t.Run("JSON result", func(t *testing.T) {
		t.Parallel()

		output, _, err := executeCLI(t, "catalog", "validate", "--json")
		if err != nil {
			t.Fatalf("catalog validate --json error = %v", err)
		}
		var result struct {
			Valid         bool   `json:"valid"`
			SchemaVersion int    `json:"schema_version"`
			Entries       int    `json:"entries"`
			Description   string `json:"description"`
		}
		if err := json.Unmarshal([]byte(output), &result); err != nil {
			t.Fatalf("catalog validate JSON cannot be decoded: %v\n%s", err, output)
		}
		if !result.Valid || result.SchemaVersion != 2 || result.Entries != 6 || result.Description == "" {
			t.Fatalf("catalog validate result = %#v", result)
		}
	})

	t.Run("invalid override is rejected", func(t *testing.T) {
		t.Parallel()

		path := filepath.Join(t.TempDir(), "invalid-catalog.json")
		if err := os.WriteFile(path, []byte(`{"schema_version":99,"description":"","entries":[]}`), 0o600); err != nil {
			t.Fatalf("os.WriteFile() error = %v", err)
		}
		_, _, err := executeCLI(t, "catalog", "validate", path)
		if err == nil {
			t.Fatal("catalog validate invalid override error = nil")
		}
		for _, text := range []string{"schema_version", "description", "entries"} {
			if !strings.Contains(err.Error(), text) {
				t.Errorf("validation error does not contain %q: %v", text, err)
			}
		}
	})

	t.Run("invalid override has structured JSON", func(t *testing.T) {
		t.Parallel()

		path := filepath.Join(t.TempDir(), "invalid-catalog.json")
		if err := os.WriteFile(path, []byte(`{"schema_version":99,"description":"","entries":[]}`), 0o600); err != nil {
			t.Fatalf("os.WriteFile() error = %v", err)
		}
		output, _, err := executeCLI(t, "catalog", "validate", path, "--json")
		if err == nil {
			t.Fatal("catalog validate invalid override --json error = nil")
		}
		var result catalogValidationResult
		if decodeErr := json.Unmarshal([]byte(output), &result); decodeErr != nil {
			t.Fatalf("catalog validate invalid JSON result cannot be decoded: %v\n%s", decodeErr, output)
		}
		if result.Valid || result.Error == "" || len(result.Issues) != 3 {
			t.Fatalf("catalog validate invalid JSON result = %#v", result)
		}
		for _, field := range []string{"schema_version", "description", "entries"} {
			found := false
			for _, issue := range result.Issues {
				if issue.Field == field {
					found = true
					break
				}
			}
			if !found {
				t.Errorf("catalog validate invalid JSON has no %s issue: %#v", field, result)
			}
		}
	})
}

// TestImageCreateDryRunValidatesCatalogueSelection verifies CLI dry runs load
// and dispatch the requested catalogue entry before rendering a workflow plan.
func TestImageCreateDryRunValidatesCatalogueSelection(t *testing.T) {
	t.Parallel()

	_, _, err := executeCLI(t, "image", "create", "--dry-run", "--catalog-id", "missing-image")
	if err == nil || !strings.Contains(err.Error(), `catalog entry "missing-image" was not found`) {
		t.Fatalf("image create dry-run missing entry error = %v", err)
	}
}

// TestImageCreateDryRunIsDeterministic verifies that planning an image build is
// repeatable and describes the complete ordered remaster workflow.
func TestImageCreateDryRunIsDeterministic(t *testing.T) {
	t.Parallel()

	arguments := []string{
		"image", "create", "--dry-run",
		"--catalog-id", "ubuntu-concept-resolute-x1e",
		"--source", "/inputs/ubuntu.iso",
		"--source-sha256", strings.Repeat("a", 64),
		"--kernel-dir", "/inputs/kernel",
		"--cache-dir", "/cache",
		"--workspace-dir", "/workspace",
		"--companion-source-dir", "/inputs/linux-armer",
		"--companion-userspace", "iptsd",
		"--output", "/output/linux-armer.iso",
	}
	first, firstErrorOutput, err := executeCLI(t, arguments...)
	if err != nil {
		t.Fatalf("first image create --dry-run error = %v", err)
	}
	second, secondErrorOutput, err := executeCLI(t, arguments...)
	if err != nil {
		t.Fatalf("second image create --dry-run error = %v", err)
	}
	if firstErrorOutput != "" || secondErrorOutput != "" {
		t.Fatalf("dry-run stderr = %q / %q, want empty", firstErrorOutput, secondErrorOutput)
	}
	if first != second {
		t.Fatalf("dry-run output is not deterministic:\nfirst:\n%s\nsecond:\n%s", first, second)
	}

	var operationPlan plan.Plan
	if err := json.Unmarshal([]byte(first), &operationPlan); err != nil {
		t.Fatalf("dry-run output cannot be decoded as a plan: %v\n%s", err, first)
	}
	if operationPlan.Operation != "image.create" || operationPlan.SchemaVersion != plan.SchemaVersion {
		t.Fatalf("dry-run plan operation/schema = %q/%d", operationPlan.Operation, operationPlan.SchemaVersion)
	}
	wantStepIDs := []string{
		"verify-source", "verify-kernel", "stage-companion", "prepare-tools", "extract-live-root", "install-kernel",
		"assemble-initramfs-root", "build-initramfs", "bind-live-media", "pair-device-trees", "repack-live-root",
		"replay-hybrid-boot", "validate-output", "publish-output",
	}
	gotStepIDs := make([]string, 0, len(operationPlan.Steps))
	for _, step := range operationPlan.Steps {
		gotStepIDs = append(gotStepIDs, step.ID)
	}
	if !reflect.DeepEqual(gotStepIDs, wantStepIDs) {
		t.Fatalf("dry-run step IDs = %v, want %v", gotStepIDs, wantStepIDs)
	}
	if operationPlan.Steps[0].Inputs["path"] != "/inputs/ubuntu.iso" ||
		operationPlan.Steps[1].Inputs["release"] != "/inputs/kernel" ||
		operationPlan.Steps[2].Inputs["source"] != "/inputs/linux-armer" ||
		operationPlan.Steps[2].Inputs["userspace"] != "iptsd-v1" ||
		operationPlan.Steps[len(operationPlan.Steps)-1].Inputs["path"] != "/output/linux-armer.iso" {
		t.Fatalf("dry-run plan inputs = %#v", operationPlan.Steps)
	}
}

// TestCleanApplyRequiresExplicitConfirmation verifies that clean-up cannot move
// a recognised workaround or create backups without affirmative consent.
func TestCleanApplyRequiresExplicitConfirmation(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	legacyPath := filepath.Join(root, "etc", "modprobe.d", "sp11-touchscreen.conf")
	if err := os.MkdirAll(filepath.Dir(legacyPath), 0o755); err != nil {
		t.Fatalf("os.MkdirAll() error = %v", err)
	}
	legacyContent := "softdep mshw0485_touch pre: spi_geni_qcom\n"
	if err := os.WriteFile(legacyPath, []byte(legacyContent), 0o644); err != nil {
		t.Fatalf("os.WriteFile() error = %v", err)
	}
	planPath := filepath.Join(t.TempDir(), "cleanup-plan.json")
	if _, _, err := executeCLI(t, "clean", "plan", "--root", root, "--output", planPath); err != nil {
		t.Fatalf("clean plan error = %v", err)
	}

	_, _, err := executeCLI(t, "clean", "apply", "--root", root, "--plan", planPath)
	if err == nil || !strings.Contains(err.Error(), "requires --yes") {
		t.Fatalf("clean apply without confirmation error = %v", err)
	}
	content, readErr := os.ReadFile(legacyPath)
	if readErr != nil {
		t.Fatalf("legacy file changed without confirmation: %v", readErr)
	}
	if string(content) != legacyContent {
		t.Fatalf("legacy file content changed without confirmation: %q", content)
	}
	if _, statErr := os.Stat(filepath.Join(root, "var", "lib", "linux-armer", "backups")); !os.IsNotExist(statErr) {
		t.Fatalf("backup directory was created without confirmation: %v", statErr)
	}
}

// TestCleanApplyWithConfirmationReturnsReceipt verifies that confirmed clean-up
// preserves the workaround in a backup and reports the exact change as JSON.
func TestCleanApplyWithConfirmationReturnsReceipt(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	legacyPath := filepath.Join(root, "etc", "modprobe.d", "sp11-touchscreen.conf")
	if err := os.MkdirAll(filepath.Dir(legacyPath), 0o755); err != nil {
		t.Fatalf("os.MkdirAll() error = %v", err)
	}
	if err := os.WriteFile(legacyPath, []byte("mshw0485_touch\n"), 0o644); err != nil {
		t.Fatalf("os.WriteFile() error = %v", err)
	}
	planPath := filepath.Join(t.TempDir(), "cleanup-plan.json")
	if _, _, err := executeCLI(t, "clean", "plan", "--root", root, "--output", planPath); err != nil {
		t.Fatalf("clean plan error = %v", err)
	}

	output, _, err := executeCLI(t, "clean", "apply", "--root", root, "--plan", planPath, "--yes", "--json")
	if err != nil {
		t.Fatalf("clean apply --yes error = %v", err)
	}
	var receipt cleanup.Receipt
	if err := json.Unmarshal([]byte(output), &receipt); err != nil {
		t.Fatalf("clean apply JSON cannot be decoded: %v\n%s", err, output)
	}
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatalf("filepath.EvalSymlinks(root) error = %v", err)
	}
	wantOriginal := filepath.Join(resolvedRoot, "etc", "modprobe.d", "sp11-touchscreen.conf")
	if len(receipt.Changes) != 1 || receipt.Changes[0].Original != wantOriginal {
		t.Fatalf("clean receipt = %#v", receipt)
	}
	if _, err := os.Stat(legacyPath); !os.IsNotExist(err) {
		t.Fatalf("recognised workaround still exists after --yes: %v", err)
	}
	if _, err := os.Stat(receipt.Changes[0].BackupPath); err != nil {
		t.Fatalf("cleanup backup is missing: %v", err)
	}
}

// TestCleanApplyUsesOnlyReviewedFindings verifies a workaround created after
// planning is preserved until it appears in a separately reviewed plan.
func TestCleanApplyUsesOnlyReviewedFindings(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	planned := filepath.Join(root, "etc", "modprobe.d", "sp11-touchscreen.conf")
	if err := os.MkdirAll(filepath.Dir(planned), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(planned, []byte("mshw0485_touch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	planPath := filepath.Join(t.TempDir(), "cleanup-plan.json")
	if _, _, err := executeCLI(t, "clean", "plan", "--root", root, "--output", planPath); err != nil {
		t.Fatalf("clean plan error = %v", err)
	}
	createdAfterReview := filepath.Join(root, "etc", "modules-load.d", "sp11-touchscreen.conf")
	if err := os.MkdirAll(filepath.Dir(createdAfterReview), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(createdAfterReview, []byte("mshw0485_touch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := executeCLI(t, "clean", "apply", "--root", root, "--plan", planPath, "--yes"); err != nil {
		t.Fatalf("clean apply error = %v", err)
	}
	if _, err := os.Stat(planned); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("planned workaround remains: %v", err)
	}
	if _, err := os.Stat(createdAfterReview); err != nil {
		t.Fatalf("new unreviewed workaround was changed: %v", err)
	}
}

// TestCleanRestoreUsesVerifiedReceipt verifies the delivery layer requires an
// explicit receipt and confirmation before recreating a removed workaround.
func TestCleanRestoreUsesVerifiedReceipt(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	legacyPath := filepath.Join(root, "etc", "modprobe.d", "sp11-touchscreen.conf")
	if err := os.MkdirAll(filepath.Dir(legacyPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacyPath, []byte("mshw0485_touch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	planPath := filepath.Join(t.TempDir(), "cleanup-plan.json")
	if _, _, err := executeCLI(t, "clean", "plan", "--root", root, "--output", planPath); err != nil {
		t.Fatalf("clean plan error = %v", err)
	}
	applyOutput, _, err := executeCLI(t, "clean", "apply", "--root", root, "--plan", planPath, "--yes", "--json")
	if err != nil {
		t.Fatalf("clean apply error = %v", err)
	}
	var receipt cleanup.Receipt
	if err := json.Unmarshal([]byte(applyOutput), &receipt); err != nil {
		t.Fatal(err)
	}
	receiptPath := filepath.Join(receipt.Backup, "receipt.json")
	if _, _, err := executeCLI(t, "clean", "restore", receiptPath, "--root", root); err == nil || !strings.Contains(err.Error(), "requires --yes") {
		t.Fatalf("clean restore without confirmation error = %v", err)
	}
	if _, err := os.Stat(legacyPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("restore changed target without confirmation: %v", err)
	}
	restoreOutput, _, err := executeCLI(t, "clean", "restore", receiptPath, "--root", root, "--yes", "--json")
	if err != nil {
		t.Fatalf("clean restore error = %v", err)
	}
	var restored cleanup.RestoreReport
	if err := json.Unmarshal([]byte(restoreOutput), &restored); err != nil {
		t.Fatal(err)
	}
	if len(restored.Restored) != 1 || restored.Restored[0] != receipt.Changes[0].Original {
		t.Fatalf("restore report = %#v, want restored legacy path", restored)
	}
	if data, err := os.ReadFile(legacyPath); err != nil || string(data) != "mshw0485_touch\n" {
		t.Fatalf("restored legacy file = %q, error %v", data, err)
	}
}

// executeCLI runs an isolated root command and returns captured standard output,
// standard error, and the command result for delivery-level assertions.
func executeCLI(t *testing.T, arguments ...string) (string, string, error) {
	t.Helper()

	var output bytes.Buffer
	var errorOutput bytes.Buffer
	command := NewRootCommand(strings.NewReader(""), &output, &errorOutput)
	command.SetArgs(append([]string{}, arguments...))
	err := command.ExecuteContext(context.Background())
	return output.String(), errorOutput.String(), err
}
