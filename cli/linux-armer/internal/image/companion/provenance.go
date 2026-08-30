package companion

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// verifySourceRevision checks exact revision and cleanliness for a source tree
// beneath Git control, unless the caller deliberately selected DevelopmentCommit.
func verifySourceRevision(ctx context.Context, runner platform.Runner, request BuildRequest) error {
	if request.Commit == DevelopmentCommit {
		return nil
	}
	controlled, err := hasGitControl(request.SourceDirectory)
	if err != nil {
		return err
	}
	if !controlled {
		return errors.New("non-Git linux-armer source requires the explicit working-tree development commit")
	}
	if runner == nil {
		return errors.New("verify git-backed companion source: command runner is required")
	}
	revision, err := runner.Capture(ctx, platform.Command{
		Name: "git", Args: []string{"-C", request.SourceDirectory, "rev-parse", "HEAD"},
	})
	if err != nil {
		return fmt.Errorf("resolve git-backed companion source revision: %w", err)
	}
	resolvedRevision := strings.TrimSpace(string(revision))
	if resolvedRevision != request.Commit {
		return fmt.Errorf("linux-armer source revision is %s, requested companion commit is %s", resolvedRevision, request.Commit)
	}
	status, err := runner.Capture(ctx, platform.Command{
		Name: "git",
		Args: []string{"-C", request.SourceDirectory, "status", "--porcelain=v1", "--untracked-files=all", "--", "."},
	})
	if err != nil {
		return fmt.Errorf("inspect git-backed companion source status: %w", err)
	}
	if strings.TrimSpace(string(status)) != "" {
		return errors.New("git-backed linux-armer source is dirty; use the explicit working-tree development commit only for development images")
	}
	return nil
}

// hasGitControl reports whether sourceRoot lies at or beneath a filesystem
// directory containing a Git control directory or worktree marker.
func hasGitControl(sourceRoot string) (bool, error) {
	current := sourceRoot
	for {
		control := filepath.Join(current, ".git")
		info, err := os.Lstat(control)
		if err == nil {
			if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() && !info.Mode().IsRegular() {
				return false, fmt.Errorf("Git control path is not a regular file or directory: %s", control)
			}
			return true, nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return false, fmt.Errorf("inspect Git control path: %w", err)
		}
		parent := filepath.Dir(current)
		if parent == current {
			return false, nil
		}
		current = parent
	}
}
