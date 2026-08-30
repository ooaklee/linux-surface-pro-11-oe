package doctor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFilepathAbsReturnsRequestedWorkspace(t *testing.T) {
	workspace := t.TempDir()
	nested := filepath.Join(workspace, "nested")
	if err := os.Mkdir(nested, 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := filepathAbs(nested)
	if err != nil {
		t.Fatalf("filepathAbs() error = %v", err)
	}
	want, err := filepath.Abs(nested)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("filepathAbs() = %q, want %q", got, want)
	}
}

func TestFilepathAbsRejectsFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "workspace.txt")
	if err := os.WriteFile(path, []byte("not a directory"), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := filepathAbs(path)
	if err == nil || !strings.Contains(err.Error(), "not a directory") {
		t.Fatalf("filepathAbs() error = %v, want not-a-directory error", err)
	}
}
