package application

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"io/fs"
	"os"
	"strconv"
)

// targetMatches determines whether one compiled target already has the exact
// intended type, bytes, mode, or absence without following a final symlink.
func targetMatches(ctx context.Context, root *os.Root, action desiredAction) (bool, error) {
	matches, _, err := inspectTarget(ctx, root, action)
	return matches, err
}

// inspectTarget returns an exact private observation checkpoint as well as the
// desired-state decision so reviewed plans detect any pre-mutation replacement.
func inspectTarget(ctx context.Context, root *os.Root, action desiredAction) (bool, string, error) {
	info, err := root.Lstat(action.change.Path)
	if errors.Is(err, fs.ErrNotExist) {
		return action.change.Kind == ChangeAbsent, targetObservation("absent"), nil
	}
	if err != nil {
		return false, "", fmt.Errorf("inspect compiled target %s: %w", action.change.ID, err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		target, readErr := root.Readlink(action.change.Path)
		if readErr != nil || len(target) > 4096 {
			return false, "", fmt.Errorf("inspect compiled target link %s", action.change.ID)
		}
		observation := targetObservation("symlink", target)
		return action.change.Kind == ChangeSymlink && target == action.linkTarget, observation, nil
	}
	if !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > maximumBackupBytes {
		return false, "", fmt.Errorf("compiled target %s is not a bounded regular file or symbolic link", action.change.ID)
	}
	file, err := root.Open(action.change.Path)
	if err != nil {
		return false, "", fmt.Errorf("open compiled target %s: %w", action.change.ID, err)
	}
	opened, statErr := file.Stat()
	if statErr != nil || !opened.Mode().IsRegular() || !os.SameFile(info, opened) {
		_ = file.Close()
		return false, "", fmt.Errorf("compiled target %s changed during inspection", action.change.ID)
	}
	digest := sha256.New()
	written, copyErr := io.Copy(digest, io.LimitReader(contextReader{context: ctx, reader: file}, maximumBackupBytes+1))
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil {
		return false, "", fmt.Errorf("hash compiled target %s: %w", action.change.ID, errors.Join(copyErr, closeErr))
	}
	if written > maximumBackupBytes || written != info.Size() {
		return false, "", fmt.Errorf("compiled target %s changed while hashing", action.change.ID)
	}
	contentSHA256 := hex.EncodeToString(digest.Sum(nil))
	observation := targetObservation(
		"file", strconv.FormatUint(uint64(info.Mode().Perm()), 8),
		strconv.FormatInt(written, 10), contentSHA256,
	)
	matches := action.change.Kind == ChangeFile && info.Mode().Perm() == action.mode.Perm() && written == action.size && contentSHA256 == action.sha256
	return matches, observation, nil
}

// targetObservation creates a domain-separated digest of private current-target state.
func targetObservation(fields ...string) string {
	digest := sha256.New()
	writeTargetObservationField(digest, "linux-armer.windows-handoff/target-observation/v1\x00")
	for _, field := range fields {
		writeTargetObservationField(digest, field)
	}
	return hex.EncodeToString(digest.Sum(nil))
}

// writeTargetObservationField writes one length-prefixed observation field.
func writeTargetObservationField(digest hash.Hash, value string) {
	_, _ = digest.Write([]byte(strconv.Itoa(len(value))))
	_, _ = digest.Write([]byte{':'})
	_, _ = digest.Write([]byte(value))
}
