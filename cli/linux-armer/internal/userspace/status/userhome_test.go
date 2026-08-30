package status

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestUserAudioStatusRequiresExplicitHome verifies per-user remnants are only
// inspected beneath the selected target-visible home and no account is inferred.
func TestUserAudioStatusRequiresExplicitHome(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	mkdir(t, filepath.Join(root, "home/alice"))
	mkdir(t, filepath.Join(root, "home/bob"))
	alicePath := filepath.Join("home/alice", legacyUserAudioPaths[0])
	bobPath := filepath.Join("home/bob", legacyUserAudioPaths[1])
	writeFile(t, root, alicePath, 0o644, "legacy Alice audio")
	writeFile(t, root, bobPath, 0o644, "legacy Bob audio")

	withoutHome, err := Inspect(Options{Root: root, Features: []Feature{FeatureAudio}})
	if err != nil {
		t.Fatal(err)
	}
	if check := findCheck(t, withoutHome, "audio-user-legacy-conflicts"); check.State != StateSkip || !strings.Contains(check.Detail, "--user-home") {
		t.Fatalf("unselected user-home check = %#v", check)
	}
	withHome, err := Inspect(Options{Root: root, UserHome: "/home/alice", Features: []Feature{FeatureAudio}})
	if err != nil {
		t.Fatal(err)
	}
	check := findCheck(t, withHome, "audio-user-legacy-conflicts")
	if check.State != StateFail || !strings.Contains(check.Detail, "/home/alice/") || strings.Contains(check.Detail, "/home/bob/") {
		t.Fatalf("selected user-home check = %#v", check)
	}
	if withHome.UserHome != "/home/alice" {
		t.Fatalf("report user home = %q", withHome.UserHome)
	}
}

// TestUserAudioStatusRejectsUnsafeHomes verifies home selection is absolute,
// canonical, present, and never a symbolic-link alias.
func TestUserAudioStatusRejectsUnsafeHomes(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	mkdir(t, filepath.Join(root, "home/alice"))
	if err := os.Symlink("alice", filepath.Join(root, "home/linked")); err != nil {
		t.Fatal(err)
	}
	for _, input := range []string{"home/alice", "/", "/home/../home/alice", "/home/missing", "/home/linked"} {
		if _, err := Inspect(Options{Root: root, UserHome: input, Features: []Feature{FeatureAudio}}); err == nil {
			t.Fatalf("Inspect(UserHome=%q) unexpectedly succeeded", input)
		}
	}
}

// TestLegacyALSAMasksAreReported verifies both exact historical distribution
// service mask paths participate in the system audio conflict result.
func TestLegacyALSAMasksAreReported(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	for _, name := range []string{"alsa-restore.service", "alsa-state.service"} {
		path := filepath.Join(root, "etc/systemd/system", name)
		mkdir(t, filepath.Dir(path))
		if err := os.Symlink("/dev/null", path); err != nil {
			t.Fatal(err)
		}
	}
	report, err := Inspect(Options{Root: root, Features: []Feature{FeatureAudio}})
	if err != nil {
		t.Fatal(err)
	}
	check := findCheck(t, report, "audio-legacy-conflicts")
	if check.State != StateFail || !strings.Contains(check.Detail, "alsa-restore.service") || !strings.Contains(check.Detail, "alsa-state.service") {
		t.Fatalf("ALSA mask conflict = %#v", check)
	}
}
