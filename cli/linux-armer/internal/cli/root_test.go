package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/catalog"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/cleanup"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/plan"
)

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
		"wizard",
	} {
		if !strings.Contains(output, text) {
			t.Errorf("help output does not contain %q:\n%s", text, output)
		}
	}
}

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
		if !strings.Contains(output, "ID") || !strings.Contains(output, "IMAGE") || !strings.Contains(output, "FORMAT") || !strings.Contains(output, "SUPPORT") {
			t.Fatalf("catalog table has no expected header:\n%s", output)
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

func TestCatalogShowDelivery(t *testing.T) {
	t.Parallel()

	t.Run("implemented entry", func(t *testing.T) {
		t.Parallel()

		output, _, err := executeCLI(t, "catalog", "show", "ubuntu-concept-resolute-x1e")
		if err != nil {
			t.Fatalf("catalog show error = %v", err)
		}
		for _, text := range []string{
			"Ubuntu Concept Resolute Desktop for X1E",
			"Architecture: arm64",
			"Support: implemented",
			"Adapter: ubuntu-casper",
			"The concept-image URL is mutable",
			"Notes:",
		} {
			if !strings.Contains(output, text) {
				t.Errorf("catalog show output does not contain %q:\n%s", text, output)
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

func TestCatalogValidateDelivery(t *testing.T) {
	t.Parallel()

	t.Run("embedded catalog", func(t *testing.T) {
		t.Parallel()

		output, _, err := executeCLI(t, "catalog", "validate")
		if err != nil {
			t.Fatalf("catalog validate error = %v", err)
		}
		if output != "catalog valid: schema 1, 6 entries\n" {
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
		if !result.Valid || result.SchemaVersion != 1 || result.Entries != 6 || result.Description == "" {
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
}

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
		"verify-source", "verify-kernel", "prepare-tools", "extract-live-root", "install-kernel",
		"assemble-initramfs-root", "build-initramfs", "pair-device-trees", "repack-live-root",
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
		operationPlan.Steps[len(operationPlan.Steps)-1].Inputs["path"] != "/output/linux-armer.iso" {
		t.Fatalf("dry-run plan inputs = %#v", operationPlan.Steps)
	}
}

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

	_, _, err := executeCLI(t, "clean", "apply", "--root", root)
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

	output, _, err := executeCLI(t, "clean", "apply", "--root", root, "--yes", "--json")
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
		t.Fatalf("recognized workaround still exists after --yes: %v", err)
	}
	if _, err := os.Stat(receipt.Changes[0].BackupPath); err != nil {
		t.Fatalf("cleanup backup is missing: %v", err)
	}
}

func executeCLI(t *testing.T, arguments ...string) (string, string, error) {
	t.Helper()

	var output bytes.Buffer
	var errorOutput bytes.Buffer
	command := NewRootCommand(strings.NewReader(""), &output, &errorOutput)
	command.SetArgs(append([]string{}, arguments...))
	err := command.ExecuteContext(context.Background())
	return output.String(), errorOutput.String(), err
}
