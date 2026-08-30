package iptsd

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

// TestRepositoryIntegrationAndLayerRecipeRemainCoherent keeps the maintained
// BitBake recipe, checked-in integration inputs, and compiled native contract
// aligned without relying on a legacy shell test.
func TestRepositoryIntegrationAndLayerRecipeRemainCoherent(t *testing.T) {
	t.Parallel()
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate repository contract test source")
	}
	repositoryRoot := filepath.Clean(filepath.Join(filepath.Dir(sourceFile), "..", "..", "..", "..", ".."))
	integrationRoot := filepath.Join(repositoryRoot, "userspace", "iptsd-sp11")
	if err := ValidateIntegration(integrationRoot); err != nil {
		t.Fatalf("validate checked-in IPTSD integration: %v", err)
	}
	if _, err := RenderIntegration(integrationRoot); err != nil {
		t.Fatalf("render checked-in IPTSD integration: %v", err)
	}

	recipePath := filepath.Join(repositoryRoot, "meta-sp11", "recipes-support", "iptsd-sp11", "iptsd-sp11_3.1.0.bb")
	recipeInfo, err := os.Lstat(recipePath)
	if err != nil || !recipeInfo.Mode().IsRegular() || recipeInfo.Size() > 64<<10 {
		t.Fatalf("inspect maintained IPTSD recipe: information=%v error=%v", recipeInfo, err)
	}
	recipe, err := os.ReadFile(recipePath)
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{
		fmt.Sprintf(`SRCREV = "%s"`, SourceCommit),
		`file://${UNPACKDIR}/LICENSE.integration`,
		`RDEPENDS:${PN} += "systemd-extra-utils"`,
		`RCONFLICTS:${PN} += "g6-pen iptsd"`,
	} {
		if !strings.Contains(string(recipe), required) {
			t.Errorf("maintained IPTSD recipe omits %q", required)
		}
	}

	privateSideband := regexp.MustCompile(`(?i)0x6e[^\r\n]*(payload|capture|identifier)`)
	checkPublic := func(label string, data []byte) {
		t.Helper()
		if strings.Contains(string(data), "/Users/") || strings.Contains(string(data), "/private/tmp/") || privateSideband.Match(data) {
			t.Errorf("public IPTSD file contains private path or sideband material: %s", label)
		}
	}
	checkPublic("meta-sp11/recipes-support/iptsd-sp11/iptsd-sp11_3.1.0.bb", recipe)
	for _, specification := range integrationFiles {
		path := filepath.Join(integrationRoot, filepath.FromSlash(specification.path))
		label := "userspace/iptsd-sp11/" + specification.path
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read public IPTSD file %s: %v", label, err)
		}
		checkPublic(label, data)
	}
}
