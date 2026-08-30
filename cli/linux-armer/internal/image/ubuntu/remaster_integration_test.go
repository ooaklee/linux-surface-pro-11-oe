package ubuntu

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/artifact"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
)

// TestRemasterIntegration builds and validates a real image when all explicit
// integration paths are supplied; normal unit-test runs remain self-contained.
func TestRemasterIntegration(t *testing.T) {
	source := os.Getenv("LINUX_ARMER_TEST_SOURCE_ISO")
	kernelDirectory := os.Getenv("LINUX_ARMER_TEST_KERNEL_DIRECTORY")
	output := os.Getenv("LINUX_ARMER_TEST_OUTPUT_ISO")
	if source == "" || kernelDirectory == "" || output == "" {
		t.Skip("set LINUX_ARMER_TEST_SOURCE_ISO, LINUX_ARMER_TEST_KERNEL_DIRECTORY, and LINUX_ARMER_TEST_OUTPUT_ISO")
	}
	entries, err := os.ReadDir(kernelDirectory)
	if err != nil {
		t.Fatal(err)
	}
	packages := make([]kernel.Package, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".deb") {
			continue
		}
		path := filepath.Join(kernelDirectory, entry.Name())
		digest, hashErr := artifact.HashFile(path)
		if hashErr != nil {
			t.Fatal(hashErr)
		}
		info, statErr := entry.Info()
		if statErr != nil {
			t.Fatal(statErr)
		}
		packages = append(packages, kernel.Package{
			Name: entry.Name(), Path: path, SHA256: digest, Size: info.Size(), Verified: true,
		})
	}
	bundle, err := kernel.NewBundle("integration", "", packages)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	result, err := NewRemasterer(nil, os.Stdout).Create(ctx, Request{
		SourceISO:   source,
		OutputISO:   output,
		Bundle:      bundle,
		ToolVersion: "integration-test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.OutputISO == "" || result.SHA256 == "" || result.Size == 0 {
		t.Fatalf("Create() returned incomplete result: %#v", result)
	}
}
