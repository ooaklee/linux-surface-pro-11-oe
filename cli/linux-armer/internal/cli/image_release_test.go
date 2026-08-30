package cli

import (
	"bytes"
	"strings"
	"testing"
)

// TestImageReleaseCommandHierarchy exposes preparation and independent validation.
func TestImageReleaseCommandHierarchy(t *testing.T) {
	command := NewRootCommand(strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
	for _, path := range [][]string{{"image", "release", "prepare"}, {"image", "release", "validate"}} {
		found, _, err := command.Find(path)
		if err != nil {
			t.Fatalf("Find(%v) error = %v", path, err)
		}
		if found == nil || found.Name() != path[len(path)-1] {
			t.Fatalf("Find(%v) returned %#v", path, found)
		}
	}
}

// TestImageReleasePrepareRequiresOneISO keeps delivery argument handling explicit.
func TestImageReleasePrepareRequiresOneISO(t *testing.T) {
	var output, errorOutput bytes.Buffer
	command := NewRootCommand(strings.NewReader(""), &output, &errorOutput)
	command.SetArgs([]string{"image", "release", "prepare"})
	if err := command.Execute(); err == nil || !strings.Contains(err.Error(), "accepts 1 arg") {
		t.Fatalf("Execute() error = %v, want exact argument failure", err)
	}
}
