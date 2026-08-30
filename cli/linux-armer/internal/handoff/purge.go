package handoff

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const (
	// purgePlanDomain separates a closed-set purge identity from every content
	// digest used by the hand-off contract.
	purgePlanDomain = "linux-armer.windows-handoff/purge-plan/v1\x00"
	// purgeConfirmationPrefix makes a content-addressed confirmation distinct
	// from blanket affirmative answers.
	purgeConfirmationPrefix = "purge "
)

// PurgePlan is an immutable operator checkpoint for deleting one currently
// validated direct child of a private Windows hand-off store.
type PurgePlan struct {
	// StoreRoot is the resolved private store root inspected when planning.
	StoreRoot string `json:"store_root"`
	// ID is the lowercase content address of the selected manifest.
	ID string `json:"id"`
	// Path is the resolved direct-child path selected when planning.
	Path string `json:"path"`
	// ClosedSetSHA256 binds the ID, every path, kind, mode, size, and current file
	// digest in the validated entry without exposing private payload bytes.
	ClosedSetSHA256 string `json:"closed_set_sha256"`
	// Confirmation is the exact content-addressed phrase required by Purge.
	Confirmation string `json:"confirmation"`
	// Summary is the deliberately redacted contract view.
	Summary Summary `json:"summary"`
}

// PlanPurge validates one content-addressed store child and returns a redacted,
// closed-set-bound checkpoint without changing the filesystem.
func PlanPurge(ctx context.Context, storeRoot, identifier string) (PurgePlan, error) {
	if ctx == nil {
		return PurgePlan{}, errors.New("plan Windows hand-off purge: context is nil")
	}
	if err := ctx.Err(); err != nil {
		return PurgePlan{}, err
	}
	resolvedStoreRoot, err := resolveStoreRoot(storeRoot)
	if err != nil {
		return PurgePlan{}, err
	}
	return planPurgeResolved(ctx, resolvedStoreRoot, identifier)
}

// Purge revalidates an unchanged plan, atomically isolates its exact direct
// child, validates it again, and removes only its verified closed set after the
// exact content-addressed confirmation.
func Purge(ctx context.Context, plan PurgePlan, exactConfirmation string) error {
	if ctx == nil {
		return errors.New("purge Windows hand-off: context is nil")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := validateSHA256(plan.ID, "Windows hand-off purge ID"); err != nil {
		return err
	}
	expectedConfirmation := purgeConfirmationPrefix + plan.ID
	if plan.Confirmation != expectedConfirmation || exactConfirmation != expectedConfirmation {
		return errors.New("Windows hand-off purge requires the exact content-addressed confirmation")
	}
	resolvedStoreRoot, err := resolveStoreRoot(plan.StoreRoot)
	if err != nil {
		return err
	}
	if resolvedStoreRoot != plan.StoreRoot {
		return errors.New("Windows hand-off purge store root does not match its resolved plan")
	}
	expectedPath, err := directStoreChild(resolvedStoreRoot, plan.ID)
	if err != nil {
		return err
	}
	if plan.Path != expectedPath {
		return errors.New("Windows hand-off purge path is not the planned direct child")
	}

	currentPlan, err := planPurgeResolved(ctx, resolvedStoreRoot, plan.ID)
	if err != nil {
		return err
	}
	if !samePurgePlan(plan, currentPlan) {
		return errors.New("Windows hand-off purge plan no longer matches the current closed set")
	}
	if err := ctx.Err(); err != nil {
		return err
	}

	quarantinePath, err := unusedPurgePath(resolvedStoreRoot, plan.ID)
	if err != nil {
		return err
	}
	if err := publishNoReplace(expectedPath, quarantinePath); err != nil {
		return fmt.Errorf("isolate planned Windows hand-off for purge: %w", err)
	}
	isIsolated := true
	restore := func(cause error) error {
		if !isIsolated {
			return cause
		}
		if restoreErr := publishNoReplace(quarantinePath, expectedPath); restoreErr != nil {
			return errors.Join(cause, fmt.Errorf("restore isolated Windows hand-off after failed purge: %w", restoreErr))
		}
		isIsolated = false
		if syncErr := syncDirectory(resolvedStoreRoot); syncErr != nil {
			return errors.Join(cause, syncErr)
		}
		return cause
	}

	isolated, err := validateStoredEntryForMaintenance(ctx, quarantinePath, plan.ID)
	if err != nil {
		return restore(fmt.Errorf("revalidate isolated Windows hand-off before purge: %w", err))
	}
	isolatedDigest := digestClosedSet(plan.ID, isolated)
	if isolatedDigest != plan.ClosedSetSHA256 || isolated.summary != plan.Summary {
		return restore(errors.New("isolated Windows hand-off changed after purge planning"))
	}
	if err := removeValidatedEntry(quarantinePath, isolated); err != nil {
		return fmt.Errorf("remove isolated Windows hand-off closed set: %w", err)
	}
	quarantineName := filepath.Base(quarantinePath)
	if err := removeRelativeNoFollow(resolvedStoreRoot, quarantineName, true); err != nil {
		return fmt.Errorf("remove isolated Windows hand-off root: %w", err)
	}
	isIsolated = false
	if err := syncDirectory(resolvedStoreRoot); err != nil {
		return err
	}
	if _, err := os.Lstat(expectedPath); !errors.Is(err, fs.ErrNotExist) {
		if err == nil {
			return errors.New("purged Windows hand-off path was recreated during deletion")
		}
		return fmt.Errorf("confirm Windows hand-off purge: %w", err)
	}
	return nil
}

// planPurgeResolved prepares one purge plan using an already resolved store
// root so Purge can compare the caller's checkpoint without path ambiguity.
func planPurgeResolved(ctx context.Context, resolvedStoreRoot, identifier string) (PurgePlan, error) {
	entryPath, err := directStoreChild(resolvedStoreRoot, identifier)
	if err != nil {
		return PurgePlan{}, err
	}
	validated, err := validateStoredEntryForMaintenance(ctx, entryPath, identifier)
	if err != nil {
		return PurgePlan{}, fmt.Errorf("validate Windows hand-off selected for purge: %w", err)
	}
	return PurgePlan{
		StoreRoot:       resolvedStoreRoot,
		ID:              identifier,
		Path:            entryPath,
		ClosedSetSHA256: digestClosedSet(identifier, validated),
		Confirmation:    purgeConfirmationPrefix + identifier,
		Summary:         validated.summary,
	}, nil
}

// samePurgePlan compares every public checkpoint field so a caller cannot
// silently retarget or weaken a previously inspected plan.
func samePurgePlan(left, right PurgePlan) bool {
	return left.StoreRoot == right.StoreRoot && left.ID == right.ID && left.Path == right.Path &&
		left.ClosedSetSHA256 == right.ClosedSetSHA256 && left.Confirmation == right.Confirmation &&
		left.Summary == right.Summary
}

// digestClosedSet returns a domain-separated digest over the content address
// and canonical current inventory of one completely validated store entry.
func digestClosedSet(identifier string, entry auditedStoreEntry) string {
	digest := sha256.New()
	writeDigestField(digest, purgePlanDomain)
	writeDigestField(digest, identifier)

	paths := make([]string, 0, len(entry.scan.entries))
	for relativePath := range entry.scan.entries {
		paths = append(paths, relativePath)
	}
	sort.Strings(paths)
	artifacts := make(map[string]storedArtifact, len(entry.artifacts))
	for _, artifact := range entry.artifacts {
		artifacts[artifact.Path] = artifact
	}
	for _, relativePath := range paths {
		scanned := entry.scan.entries[relativePath]
		writeDigestField(digest, relativePath)
		writeDigestField(digest, string(scanned.kind))
		writeDigestField(digest, strconv.FormatUint(uint64(scanned.snapshot.mode.Perm()), 8))
		if scanned.kind == entryKindFile {
			artifact := artifacts[relativePath]
			writeDigestField(digest, strconv.FormatInt(artifact.Size, 10))
			writeDigestField(digest, artifact.SHA256)
		}
	}
	return hex.EncodeToString(digest.Sum(nil))
}

// writeDigestField adds one length-prefixed value to a hash without ambiguous
// concatenation between neighbouring fields.
func writeDigestField(digest hash.Hash, value string) {
	_, _ = digest.Write([]byte(strconv.Itoa(len(value))))
	_, _ = digest.Write([]byte{':'})
	_, _ = digest.Write([]byte(value))
}

// unusedPurgePath chooses an absent private-store direct child for atomic
// isolation without including reusable private identity in its name.
func unusedPurgePath(storeRoot, identifier string) (string, error) {
	for attempt := 0; attempt < 32; attempt++ {
		randomBytes := make([]byte, 12)
		if _, err := rand.Read(randomBytes); err != nil {
			return "", fmt.Errorf("generate Windows hand-off purge isolation name: %w", err)
		}
		name := ".purge-" + identifier[:12] + "-" + hex.EncodeToString(randomBytes)
		candidate := filepath.Join(storeRoot, name)
		if filepath.Dir(candidate) != storeRoot {
			return "", errors.New("Windows hand-off purge isolation path escaped its store")
		}
		if _, err := os.Lstat(candidate); errors.Is(err, fs.ErrNotExist) {
			return candidate, nil
		} else if err != nil {
			return "", fmt.Errorf("inspect Windows hand-off purge isolation path: %w", err)
		}
	}
	return "", errors.New("could not allocate an unused Windows hand-off purge isolation path")
}

// removeValidatedEntry removes every verified file and then every non-root
// directory deepest-first through no-follow descriptor-relative operations.
func removeValidatedEntry(entryRoot string, entry auditedStoreEntry) error {
	files := make([]string, 0, len(entry.artifacts))
	for _, artifact := range entry.artifacts {
		files = append(files, artifact.Path)
	}
	sort.Sort(sort.Reverse(sort.StringSlice(files)))
	for _, relativePath := range files {
		if err := removeRelativeNoFollow(entryRoot, relativePath, false); err != nil {
			return err
		}
	}

	directories := make([]string, 0, len(entry.scan.entries))
	for relativePath, scanned := range entry.scan.entries {
		if relativePath != "." && scanned.kind == entryKindDirectory {
			directories = append(directories, relativePath)
		}
	}
	sort.Slice(directories, func(left, right int) bool {
		leftDepth := strings.Count(directories[left], "/")
		rightDepth := strings.Count(directories[right], "/")
		if leftDepth != rightDepth {
			return leftDepth > rightDepth
		}
		return directories[left] > directories[right]
	})
	for _, relativePath := range directories {
		if err := removeRelativeNoFollow(entryRoot, relativePath, true); err != nil {
			return err
		}
	}
	return nil
}
