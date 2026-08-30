package handoff

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

// storeFixture contains one complete, internally consistent hand-off source and
// its not-yet-created private store path.
type storeFixture struct {
	// Source is the complete source directory supplied to Import.
	Source string
	// Store is the private content-addressed store root supplied to Import.
	Store string
	// Contract is the validated source contract with test payload identities.
	Contract Contract
	// Manifest is the exact canonical manifest byte sequence written to Source.
	Manifest []byte
}

// TestImportPublishesPrivateClosedSet verifies exact-byte identity, copied
// contents, private modes, redacted output, and read-only listing.
func TestImportPublishesPrivateClosedSet(t *testing.T) {
	t.Parallel()
	fixture := newStoreFixture(t)

	result, err := Import(context.Background(), fixture.Source, fixture.Store)
	if err != nil {
		t.Fatal(err)
	}
	if result.ID != digestBytes(fixture.Manifest) {
		t.Fatalf("Import() ID = %q, want exact manifest digest", result.ID)
	}
	if result.Existing {
		t.Fatal("Import() reported a new publication as existing")
	}
	resolvedParent, err := filepath.EvalSymlinks(filepath.Dir(fixture.Store))
	if err != nil {
		t.Fatal(err)
	}
	expectedPath := filepath.Join(resolvedParent, filepath.Base(fixture.Store), result.ID)
	if result.Path != expectedPath {
		t.Fatalf("Import() path = %q, want direct content-addressed child", result.Path)
	}
	storedManifest, err := os.ReadFile(filepath.Join(result.Path, ManifestFilename))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(storedManifest, fixture.Manifest) {
		t.Fatal("stored manifest bytes differ from the exact imported bytes")
	}
	assertPrivateEntryModes(t, fixture.Store, result.Path)
	assertRedactedJSON(t, result)

	listed, err := List(context.Background(), fixture.Store)
	if err != nil {
		t.Fatal(err)
	}
	if len(listed) != 1 || listed[0].ID != result.ID || listed[0].Summary != result.Summary {
		t.Fatalf("List() = %#v, want the imported redacted summary", listed)
	}
	assertRedactedJSON(t, listed)
}

// TestImportBluetoothOnlyClosedSet verifies a valid address-only hand-off has
// no invented payload directory and still receives private storage treatment.
func TestImportBluetoothOnlyClosedSet(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	fixture := newStoreFixtureAt(t, filepath.Join(root, "source"), filepath.Join(root, "store"), func(contract *Contract) {
		contract.PlatformFirmware = PlatformFirmwareSection{Reason: testAbsentReason(AbsentReasonNotRequested)}
	})
	result, err := Import(context.Background(), fixture.Source, fixture.Store)
	if err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(result.Path)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != ManifestFilename {
		t.Fatalf("address-only stored entries = %#v, want only the manifest", entries)
	}
	assertPrivateEntryModes(t, fixture.Store, result.Path)
}

// TestImportIsIdempotent verifies that an identical existing entry is fully
// revalidated and returned without replacement.
func TestImportIsIdempotent(t *testing.T) {
	t.Parallel()
	fixture := newStoreFixture(t)
	first, err := Import(context.Background(), fixture.Source, fixture.Store)
	if err != nil {
		t.Fatal(err)
	}
	firstInfo, err := os.Lstat(first.Path)
	if err != nil {
		t.Fatal(err)
	}
	second, err := Import(context.Background(), fixture.Source, fixture.Store)
	if err != nil {
		t.Fatal(err)
	}
	secondInfo, err := os.Lstat(second.Path)
	if err != nil {
		t.Fatal(err)
	}
	if !second.Existing || first.ID != second.ID || first.Path != second.Path || !os.SameFile(firstInfo, secondInfo) {
		t.Fatalf("second Import() = %#v, want the same revalidated entry", second)
	}
}

// TestImportConcurrentPublication verifies atomic no-replace publication lets
// two identical imports converge on one fully validated store child.
func TestImportConcurrentPublication(t *testing.T) {
	t.Parallel()
	fixture := newStoreFixture(t)
	type outcome struct {
		result ImportResult
		err    error
	}
	start := make(chan struct{})
	outcomes := make(chan outcome, 2)
	for index := 0; index < 2; index++ {
		go func() {
			<-start
			result, err := Import(context.Background(), fixture.Source, fixture.Store)
			outcomes <- outcome{result: result, err: err}
		}()
	}
	close(start)
	first := <-outcomes
	second := <-outcomes
	for _, item := range []outcome{first, second} {
		if item.err != nil {
			t.Fatal(item.err)
		}
		if item.result.ID != digestBytes(fixture.Manifest) {
			t.Fatalf("concurrent Import() ID = %q, want manifest digest", item.result.ID)
		}
	}
	if first.result.Path != second.result.Path {
		t.Fatalf("concurrent Import() paths differ: %q and %q", first.result.Path, second.result.Path)
	}
	if first.result.Existing == second.result.Existing {
		t.Fatalf("concurrent imports existing states = %t and %t, want one publisher", first.result.Existing, second.result.Existing)
	}
	listed, err := List(context.Background(), fixture.Store)
	if err != nil {
		t.Fatal(err)
	}
	if len(listed) != 1 || listed[0].ID != first.result.ID {
		t.Fatalf("List() after concurrent imports = %#v, want one entry", listed)
	}
}

// TestImportRejectsNonClosedSources covers undeclared entries, links, special
// files, alternate separators, missing paths, and linked roots.
func TestImportRejectsNonClosedSources(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		mutate func(*testing.T, storeFixture)
	}{
		{
			name: "extra file",
			mutate: func(t *testing.T, fixture storeFixture) {
				writeTestFile(t, filepath.Join(fixture.Source, "unexpected.txt"), []byte("extra"), 0o644)
			},
		},
		{
			name: "extra directory",
			mutate: func(t *testing.T, fixture storeFixture) {
				mustMkdirAll(t, filepath.Join(fixture.Source, "unexpected"), 0o755)
			},
		},
		{
			name: "alternate separator",
			mutate: func(t *testing.T, fixture storeFixture) {
				writeTestFile(t, filepath.Join(fixture.Source, `unexpected\name`), []byte("extra"), 0o644)
			},
		},
		{
			name: "symbolic link file",
			mutate: func(t *testing.T, fixture storeFixture) {
				target := filepath.Join(t.TempDir(), "target")
				writeTestFile(t, target, []byte("external"), 0o600)
				if err := os.Symlink(target, filepath.Join(fixture.Source, "unexpected-link")); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "symbolic link payload leaf",
			mutate: func(t *testing.T, fixture storeFixture) {
				record := fixture.Contract.PlatformFirmware.Files[0]
				payload := filepath.Join(fixture.Source, filepath.FromSlash(record.PayloadPath))
				if err := os.Remove(payload); err != nil {
					t.Fatal(err)
				}
				target := filepath.Join(t.TempDir(), record.SourceName)
				writeTestFile(t, target, testPayloadBytes(0, record.ID), 0o600)
				if err := os.Symlink(target, payload); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "symbolic link payload parent",
			mutate: func(t *testing.T, fixture storeFixture) {
				payloadRoot := filepath.Join(fixture.Source, "payload")
				if err := os.RemoveAll(payloadRoot); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(t.TempDir(), payloadRoot); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "extra named pipe",
			mutate: func(t *testing.T, fixture storeFixture) {
				if err := unix.Mkfifo(filepath.Join(fixture.Source, "unexpected-pipe"), 0o600); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "manifest named pipe",
			mutate: func(t *testing.T, fixture storeFixture) {
				path := filepath.Join(fixture.Source, ManifestFilename)
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				if err := unix.Mkfifo(path, 0o600); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "payload named pipe",
			mutate: func(t *testing.T, fixture storeFixture) {
				record := fixture.Contract.PlatformFirmware.Files[0]
				path := filepath.Join(fixture.Source, filepath.FromSlash(record.PayloadPath))
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				if err := unix.Mkfifo(path, 0o600); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "missing payload",
			mutate: func(t *testing.T, fixture storeFixture) {
				record := fixture.Contract.PlatformFirmware.Files[0]
				if err := os.Remove(filepath.Join(fixture.Source, filepath.FromSlash(record.PayloadPath))); err != nil {
					t.Fatal(err)
				}
			},
		},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			fixture := newStoreFixture(t)
			test.mutate(t, fixture)
			if _, err := Import(context.Background(), fixture.Source, fixture.Store); err == nil {
				t.Fatal("Import() succeeded for a non-closed source")
			}
			assertNoPublishedEntries(t, fixture.Store)
		})
	}
}

// TestImportRejectsLinkedRoots verifies that source, store, and new-store
// parent final components cannot redirect storage through symbolic links.
func TestImportRejectsLinkedRoots(t *testing.T) {
	t.Parallel()
	t.Run("source root", func(t *testing.T) {
		fixture := newStoreFixture(t)
		linkedSource := filepath.Join(t.TempDir(), "source-link")
		if err := os.Symlink(fixture.Source, linkedSource); err != nil {
			t.Fatal(err)
		}
		if _, err := Import(context.Background(), linkedSource, fixture.Store); err == nil {
			t.Fatal("Import() accepted a symbolic-link source root")
		}
	})
	t.Run("store root", func(t *testing.T) {
		fixture := newStoreFixture(t)
		actualStore := filepath.Join(t.TempDir(), "actual-store")
		mustMkdirAll(t, actualStore, privateDirectoryMode)
		linkedStore := filepath.Join(t.TempDir(), "store-link")
		if err := os.Symlink(actualStore, linkedStore); err != nil {
			t.Fatal(err)
		}
		if _, err := Import(context.Background(), fixture.Source, linkedStore); err == nil {
			t.Fatal("Import() accepted a symbolic-link store root")
		}
	})
	t.Run("new store parent", func(t *testing.T) {
		fixture := newStoreFixture(t)
		actualParent := t.TempDir()
		linkedParent := filepath.Join(t.TempDir(), "parent-link")
		if err := os.Symlink(actualParent, linkedParent); err != nil {
			t.Fatal(err)
		}
		if _, err := Import(context.Background(), fixture.Source, filepath.Join(linkedParent, "store")); err == nil {
			t.Fatal("Import() accepted a symbolic-link final store parent")
		}
	})
}

// TestImportRejectsPermissiveStoreRoot verifies an existing private store is
// never silently tightened or accepted after another workflow created it.
func TestImportRejectsPermissiveStoreRoot(t *testing.T) {
	t.Parallel()
	fixture := newStoreFixture(t)
	mustMkdirAll(t, fixture.Store, 0o755)
	if _, err := Import(context.Background(), fixture.Source, fixture.Store); err == nil {
		t.Fatal("Import() accepted a store root that was not mode 0700")
	}
	info, err := os.Lstat(fixture.Store)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o755 {
		t.Fatalf("Import() changed rejected store mode to %04o", info.Mode().Perm())
	}
}

// TestRecordCaseDistinctPathRejectsCollision pins case-collision detection on
// both case-sensitive and case-insensitive test filesystems.
func TestRecordCaseDistinctPathRejectsCollision(t *testing.T) {
	t.Parallel()
	seen := make(map[string]string)
	if err := recordCaseDistinctPath(seen, "payload/Firmware.bin"); err != nil {
		t.Fatal(err)
	}
	if err := recordCaseDistinctPath(seen, "PAYLOAD/firmware.bin"); err == nil {
		t.Fatal("recordCaseDistinctPath() accepted differently cased paths")
	}
}

// TestImportRejectsPayloadIdentityMismatch verifies independent size and digest
// enforcement without replacing a corrupt source.
func TestImportRejectsPayloadIdentityMismatch(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		mutate func([]byte) []byte
	}{
		{name: "size", mutate: func(data []byte) []byte { return append(data, 'x') }},
		{name: "digest", mutate: func(data []byte) []byte {
			mutated := append([]byte(nil), data...)
			mutated[0] ^= 0xff
			return mutated
		}},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			fixture := newStoreFixture(t)
			record := fixture.Contract.PlatformFirmware.Files[0]
			path := filepath.Join(fixture.Source, filepath.FromSlash(record.PayloadPath))
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			writeTestFile(t, path, test.mutate(data), 0o644)
			if _, err := Import(context.Background(), fixture.Source, fixture.Store); err == nil {
				t.Fatal("Import() accepted a payload identity mismatch")
			}
			assertNoPublishedEntries(t, fixture.Store)
		})
	}
}

// TestImportDetectsSourceMutation exercises deterministic drift before hashing,
// during copying, and immediately before publication.
func TestImportDetectsSourceMutation(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		build func(*testing.T, storeFixture) importHooks
	}{
		{
			name: "after source scan",
			build: func(t *testing.T, fixture storeFixture) importHooks {
				return importHooks{afterSourceScan: func() error {
					record := fixture.Contract.PlatformFirmware.Files[0]
					path := filepath.Join(fixture.Source, filepath.FromSlash(record.PayloadPath))
					writeTestFile(t, path, []byte(strings.Repeat("z", int(record.Size))), 0o644)
					return nil
				}}
			},
		},
		{
			name: "during copy",
			build: func(t *testing.T, fixture storeFixture) importHooks {
				record := fixture.Contract.PlatformFirmware.Files[0]
				calls := 0
				return importHooks{afterPayloadOpen: func(relativePath string) error {
					if relativePath != record.PayloadPath {
						return nil
					}
					calls++
					if calls == 2 {
						path := filepath.Join(fixture.Source, filepath.FromSlash(record.PayloadPath))
						writeTestFile(t, path, []byte(strings.Repeat("y", int(record.Size))), 0o644)
					}
					return nil
				}}
			},
		},
		{
			name: "before publication",
			build: func(t *testing.T, fixture storeFixture) importHooks {
				return importHooks{beforePublish: func() error {
					writeTestFile(t, filepath.Join(fixture.Source, "late-extra"), []byte("late"), 0o600)
					return nil
				}}
			},
		},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			fixture := newStoreFixture(t)
			if _, err := importWithHooks(context.Background(), fixture.Source, fixture.Store, test.build(t, fixture)); err == nil {
				t.Fatal("importWithHooks() accepted source mutation")
			}
			assertNoPublishedEntries(t, fixture.Store)
		})
	}
}

// TestImportHonoursCancellation verifies cancellation before work and at the
// final pre-publication boundary without leaving staging data.
func TestImportHonoursCancellation(t *testing.T) {
	t.Parallel()
	fixture := newStoreFixture(t)
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Import(cancelled, fixture.Source, fixture.Store); !errors.Is(err, context.Canceled) {
		t.Fatalf("Import(cancelled) error = %v, want context cancellation", err)
	}

	fixture = newStoreFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	hooks := importHooks{beforePublish: func() error {
		cancel()
		return nil
	}}
	if _, err := importWithHooks(ctx, fixture.Source, fixture.Store, hooks); !errors.Is(err, context.Canceled) {
		t.Fatalf("importWithHooks(cancelled) error = %v, want context cancellation", err)
	}
	assertNoPublishedEntries(t, fixture.Store)
}

// TestImportRejectsCorruptExistingEntry verifies idempotence never overwrites a
// conflicting or damaged content-addressed child.
func TestImportRejectsCorruptExistingEntry(t *testing.T) {
	t.Parallel()
	fixture := newStoreFixture(t)
	result, err := Import(context.Background(), fixture.Source, fixture.Store)
	if err != nil {
		t.Fatal(err)
	}
	record := fixture.Contract.PlatformFirmware.Files[0]
	storedPayload := filepath.Join(result.Path, filepath.FromSlash(record.PayloadPath))
	corrupt := []byte(strings.Repeat("c", int(record.Size)))
	writeTestFile(t, storedPayload, corrupt, privateFileMode)
	if _, err := Import(context.Background(), fixture.Source, fixture.Store); err == nil || !strings.Contains(err.Error(), "corrupt or conflicting") {
		t.Fatalf("Import() error = %v, want corrupt-existing rejection", err)
	}
	remaining, err := os.ReadFile(storedPayload)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(remaining, corrupt) {
		t.Fatal("Import() replaced the corrupt existing entry")
	}
}

// TestImportRejectsConflictingSymlinkEntry verifies publication cannot follow
// or replace an object already occupying the content-addressed name.
func TestImportRejectsConflictingSymlinkEntry(t *testing.T) {
	t.Parallel()
	fixture := newStoreFixture(t)
	mustMkdirAll(t, fixture.Store, privateDirectoryMode)
	identifier := digestBytes(fixture.Manifest)
	if err := os.Symlink(fixture.Source, filepath.Join(fixture.Store, identifier)); err != nil {
		t.Fatal(err)
	}
	if _, err := Import(context.Background(), fixture.Source, fixture.Store); err == nil {
		t.Fatal("Import() accepted a conflicting symbolic-link entry")
	}
	info, err := os.Lstat(filepath.Join(fixture.Store, identifier))
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("conflicting entry was replaced: info=%v error=%v", info, err)
	}
}

// TestImportRejectsOverlappingRoots verifies neither source-inside-store nor
// store-inside-source layouts can be selected.
func TestImportRejectsOverlappingRoots(t *testing.T) {
	t.Parallel()
	fixture := newStoreFixture(t)
	insideSource := filepath.Join(fixture.Source, "store")
	if _, err := Import(context.Background(), fixture.Source, insideSource); err == nil {
		t.Fatal("Import() accepted a store within its source")
	}
	if _, err := os.Lstat(insideSource); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("overlap rejection created the prospective store: %v", err)
	}

	fixture = newStoreFixture(t)
	storeParent := filepath.Dir(fixture.Source)
	if err := os.Chmod(storeParent, privateDirectoryMode); err != nil {
		t.Fatal(err)
	}
	if _, err := Import(context.Background(), fixture.Source, storeParent); err == nil {
		t.Fatal("Import() accepted a source within its store")
	}
}

// TestListRejectsUnexpectedOrCorruptEntries verifies List is an audited view,
// not a permissive directory enumeration.
func TestListRejectsUnexpectedOrCorruptEntries(t *testing.T) {
	t.Parallel()
	fixture := newStoreFixture(t)
	result, err := Import(context.Background(), fixture.Source, fixture.Store)
	if err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(fixture.Store, "unexpected"), []byte("extra"), privateFileMode)
	if _, err := List(context.Background(), fixture.Store); err == nil {
		t.Fatal("List() accepted an unexpected store entry")
	}
	if err := os.Remove(filepath.Join(fixture.Store, "unexpected")); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(result.Path, ManifestFilename), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := List(context.Background(), fixture.Store); err == nil {
		t.Fatal("List() accepted a corrupt private entry")
	}
}

// TestPlanAndPurgeEnforceCheckpoint verifies strict confirmation, drift
// detection, path binding, cancellation, and retention after rejection.
func TestPlanAndPurgeEnforceCheckpoint(t *testing.T) {
	t.Parallel()
	fixture := newStoreFixture(t)
	result, err := Import(context.Background(), fixture.Source, fixture.Store)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := PlanPurge(context.Background(), fixture.Store, result.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.ClosedSetSHA256) != sha256.Size*2 || plan.Confirmation != purgeConfirmationPrefix+result.ID {
		t.Fatalf("PlanPurge() = %#v, want a bound digest and exact confirmation", plan)
	}
	assertRedactedJSON(t, plan)

	for _, confirmation := range []string{"", "yes", "purge", "PURGE " + result.ID} {
		if err := Purge(context.Background(), plan, confirmation); err == nil {
			t.Fatalf("Purge() accepted non-exact confirmation %q", confirmation)
		}
		assertPathExists(t, result.Path)
	}

	tampered := plan
	tampered.Path = fixture.Store
	if err := Purge(context.Background(), tampered, tampered.Confirmation); err == nil {
		t.Fatal("Purge() accepted a non-child planned path")
	}
	assertPathExists(t, result.Path)
	tampered = plan
	tampered.ClosedSetSHA256 = strings.Repeat("0", sha256.Size*2)
	if err := Purge(context.Background(), tampered, tampered.Confirmation); err == nil {
		t.Fatal("Purge() accepted a changed closed-set checkpoint")
	}
	assertPathExists(t, result.Path)

	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if err := Purge(cancelled, plan, plan.Confirmation); !errors.Is(err, context.Canceled) {
		t.Fatalf("Purge(cancelled) error = %v, want context cancellation", err)
	}
	assertPathExists(t, result.Path)
	if _, err := PlanPurge(context.Background(), fixture.Store, "../escape"); err == nil {
		t.Fatal("PlanPurge() accepted a path-like identifier")
	}
}

// TestPurgeRejectsClosedSetDrift verifies file bytes, permissions, and additions
// are revalidated against the operator's plan before isolation.
func TestPurgeRejectsClosedSetDrift(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		mutate func(*testing.T, storeFixture, ImportResult)
	}{
		{
			name: "payload bytes",
			mutate: func(t *testing.T, fixture storeFixture, result ImportResult) {
				record := fixture.Contract.PlatformFirmware.Files[0]
				path := filepath.Join(result.Path, filepath.FromSlash(record.PayloadPath))
				writeTestFile(t, path, []byte(strings.Repeat("d", int(record.Size))), privateFileMode)
			},
		},
		{
			name: "payload mode",
			mutate: func(t *testing.T, fixture storeFixture, result ImportResult) {
				record := fixture.Contract.PlatformFirmware.Files[0]
				if err := os.Chmod(filepath.Join(result.Path, filepath.FromSlash(record.PayloadPath)), 0o644); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "extra path",
			mutate: func(t *testing.T, _ storeFixture, result ImportResult) {
				writeTestFile(t, filepath.Join(result.Path, "extra"), []byte("drift"), privateFileMode)
			},
		},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			fixture := newStoreFixture(t)
			result, err := Import(context.Background(), fixture.Source, fixture.Store)
			if err != nil {
				t.Fatal(err)
			}
			plan, err := PlanPurge(context.Background(), fixture.Store, result.ID)
			if err != nil {
				t.Fatal(err)
			}
			test.mutate(t, fixture, result)
			if err := Purge(context.Background(), plan, plan.Confirmation); err == nil {
				t.Fatal("Purge() accepted closed-set drift")
			}
			assertPathExists(t, result.Path)
		})
	}
}

// TestPurgeDoesNotFollowDriftedParentLink verifies a planned entry cannot turn
// a payload parent into an instruction to touch an external directory.
func TestPurgeDoesNotFollowDriftedParentLink(t *testing.T) {
	t.Parallel()
	fixture := newStoreFixture(t)
	result, err := Import(context.Background(), fixture.Source, fixture.Store)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := PlanPurge(context.Background(), fixture.Store, result.ID)
	if err != nil {
		t.Fatal(err)
	}
	payloadRoot := filepath.Join(result.Path, "payload")
	movedPayload := filepath.Join(result.Path, "payload-moved")
	if err := os.Rename(payloadRoot, movedPayload); err != nil {
		t.Fatal(err)
	}
	external := t.TempDir()
	sentinel := filepath.Join(external, "sentinel")
	writeTestFile(t, sentinel, []byte("keep"), 0o600)
	if err := os.Symlink(external, payloadRoot); err != nil {
		t.Fatal(err)
	}
	if err := Purge(context.Background(), plan, plan.Confirmation); err == nil {
		t.Fatal("Purge() accepted a linked payload parent after planning")
	}
	assertPathExists(t, sentinel)
}

// TestPurgeRemovesOnlySelectedDirectChild verifies the happy path and retains a
// second valid content-addressed sibling without temporary remnants.
func TestPurgeRemovesOnlySelectedDirectChild(t *testing.T) {
	t.Parallel()
	fixture := newStoreFixture(t)
	first, err := Import(context.Background(), fixture.Source, fixture.Store)
	if err != nil {
		t.Fatal(err)
	}
	secondFixture := newStoreFixtureAt(t, filepath.Join(t.TempDir(), "source"), fixture.Store, func(contract *Contract) {
		contract.CreatedAt = "2026-08-30T12:35:57Z"
	})
	second, err := Import(context.Background(), secondFixture.Source, fixture.Store)
	if err != nil {
		t.Fatal(err)
	}
	if first.ID == second.ID {
		t.Fatal("test fixtures unexpectedly produced the same content address")
	}
	plan, err := PlanPurge(context.Background(), fixture.Store, first.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := Purge(context.Background(), plan, plan.Confirmation); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(first.Path); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("purged path still exists or cannot be inspected: %v", err)
	}
	assertPathExists(t, second.Path)
	entries, err := os.ReadDir(fixture.Store)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != second.ID {
		t.Fatalf("store entries after Purge() = %#v, want only untouched sibling", entries)
	}
}

// newStoreFixture creates one complete fixture beneath a fresh temporary root.
func newStoreFixture(t *testing.T) storeFixture {
	t.Helper()
	root := t.TempDir()
	return newStoreFixtureAt(t, filepath.Join(root, "source"), filepath.Join(root, "store"), nil)
}

// newStoreFixtureAt writes a complete source at an explicit path and optionally
// adjusts non-payload contract fields before canonical manifest generation.
func newStoreFixtureAt(t *testing.T, source, store string, mutate func(*Contract)) storeFixture {
	t.Helper()
	mustMkdirAll(t, source, 0o755)
	contract := decodeGoldenContract(t)
	if mutate != nil {
		mutate(&contract)
	}
	for index := range contract.PlatformFirmware.Files {
		record := &contract.PlatformFirmware.Files[index]
		payload := testPayloadBytes(index, record.ID)
		record.Size = int64(len(payload))
		record.SHA256 = digestBytes(payload)
		path := filepath.Join(source, filepath.FromSlash(record.PayloadPath))
		mustMkdirAll(t, filepath.Dir(path), 0o755)
		writeTestFile(t, path, payload, 0o644)
	}
	var document bytes.Buffer
	if err := contract.WriteJSON(&document); err != nil {
		t.Fatal(err)
	}
	manifest := append([]byte(nil), document.Bytes()...)
	writeTestFile(t, filepath.Join(source, ManifestFilename), manifest, 0o644)
	return storeFixture{Source: source, Store: store, Contract: contract, Manifest: manifest}
}

// testPayloadBytes returns stable non-empty bytes unique to one compiled
// firmware identity.
func testPayloadBytes(index int, identifier string) []byte {
	return []byte(fmt.Sprintf("linux-armer private test payload %02d for %s\n", index, identifier))
}

// mustMkdirAll creates a test directory tree and enforces the requested mode on
// the final directory despite the process umask.
func mustMkdirAll(t *testing.T, path string, mode fs.FileMode) {
	t.Helper()
	if err := os.MkdirAll(path, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

// writeTestFile writes deterministic test bytes and enforces the requested
// permissions on both newly created and existing files.
func writeTestFile(t *testing.T, path string, data []byte, mode fs.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, data, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

// assertPrivateEntryModes requires a mode-0700 store and directory tree with
// mode-0600 regular files.
func assertPrivateEntryModes(t *testing.T, storeRoot, entryRoot string) {
	t.Helper()
	storeInfo, err := os.Lstat(storeRoot)
	if err != nil {
		t.Fatal(err)
	}
	if storeInfo.Mode().Perm() != privateDirectoryMode {
		t.Fatalf("store root mode = %04o, want 0700", storeInfo.Mode().Perm())
	}
	err = filepath.WalkDir(entryRoot, func(path string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		if info.IsDir() && info.Mode().Perm() != privateDirectoryMode {
			return fmt.Errorf("directory %s mode = %04o, want 0700", item.Name(), info.Mode().Perm())
		}
		if info.Mode().IsRegular() && info.Mode().Perm() != privateFileMode {
			return fmt.Errorf("file %s mode = %04o, want 0600", item.Name(), info.Mode().Perm())
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

// assertRedactedJSON ensures public store and purge results contain no reusable
// private address or hardware-binding material from the fixture.
func assertRedactedJSON(t *testing.T, value any) {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	for _, privateValue := range []string{
		"10:20:30:40:50:60",
		"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
		"094fb62588717c3c117b6a5ce3ada6a3d2c247c306239cd0f62f432ea688f600",
		"45cf6ef73487f756b500d61d3bdc68eb0b1cd32050559c91de1595d4b2294910",
	} {
		if bytes.Contains(encoded, []byte(privateValue)) {
			t.Fatalf("public JSON disclosed private hand-off material: %s", encoded)
		}
	}
}

// assertNoPublishedEntries permits an absent or empty store but rejects leaked
// staging directories and content-addressed children after a failed import.
func assertNoPublishedEntries(t *testing.T, storeRoot string) {
	t.Helper()
	entries, err := os.ReadDir(storeRoot)
	if errors.Is(err, fs.ErrNotExist) {
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		names := make([]string, 0, len(entries))
		for _, entry := range entries {
			names = append(names, entry.Name())
		}
		t.Fatalf("failed import left store entries: %v", names)
	}
}

// assertPathExists requires one expected file or directory to remain present.
func assertPathExists(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); err != nil {
		t.Fatalf("expected path %s to remain: %v", path, err)
	}
}

// TestDigestBytesPinsLowercaseSHA256 verifies the store identifier helper's
// exact lowercase encoding independently of manifest generation.
func TestDigestBytesPinsLowercaseSHA256(t *testing.T) {
	t.Parallel()
	digest := sha256.Sum256([]byte("manifest"))
	want := hex.EncodeToString(digest[:])
	if got := digestBytes([]byte("manifest")); got != want || got != strings.ToLower(got) {
		t.Fatalf("digestBytes() = %q, want %q", got, want)
	}
}
