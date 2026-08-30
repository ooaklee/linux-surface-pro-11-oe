package plan

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// TestJournalSaveLeavesPredictableSymlinkTrapUntouched proves journal
// checkpoints use random exclusive staging instead of following the former
// predictable temporary pathname.
func TestJournalSaveLeavesPredictableSymlinkTrapUntouched(t *testing.T) {
	t.Parallel()

	directory := t.TempDir()
	journalPath := filepath.Join(directory, "image.iso.journal.json")
	victimPath := filepath.Join(directory, "victim")
	victimBytes := []byte("must remain unchanged")
	if err := os.WriteFile(victimPath, victimBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	trapPath := journalPath + ".tmp"
	if err := os.Symlink(victimPath, trapPath); err != nil {
		t.Fatal(err)
	}

	journal := NewJournal("image.create")
	journal.Complete("verify-source", map[string]string{"source.iso": "digest"})
	if err := journal.Save(journalPath); err != nil {
		t.Fatalf("Save() error = %v", err)
	}
	actualVictim, err := os.ReadFile(victimPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(actualVictim, victimBytes) {
		t.Fatalf("symlink victim bytes = %q, want %q", actualVictim, victimBytes)
	}
	trapInfo, err := os.Lstat(trapPath)
	if err != nil {
		t.Fatal(err)
	}
	if trapInfo.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("predictable journal trap is no longer a symbolic link: %s", trapPath)
	}
}
