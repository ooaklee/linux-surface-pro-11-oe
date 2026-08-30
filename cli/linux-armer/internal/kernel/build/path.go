package build

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"
)

const (
	// maximumGitURLBytes bounds source provenance and command arguments.
	maximumGitURLBytes = 2048
	// maximumGitRefBytes bounds source paths and remote ref lookups.
	maximumGitRefBytes = 255
	// maximumBuildJobs prevents accidental or hostile unbounded parallelism.
	maximumBuildJobs = 512
)

// gitRefComponentExpression accepts conservative branch and tag characters.
var gitRefComponentExpression = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]*$`)

// resolvedRequest contains canonical, fully defaulted planning inputs.
type resolvedRequest struct {
	// repositoryRoot is the canonical containment boundary.
	repositoryRoot string
	// workDirectory is the canonical private work directory.
	workDirectory string
	// outputDirectory is the canonical new output directory.
	outputDirectory string
	// gitURL is the validated source repository.
	gitURL string
	// gitRef is the validated branch or tag.
	gitRef string
	// jobs is zero or the requested bounded parallelism.
	jobs int
	// resetSource permits reset inside the owned volume only.
	resetSource bool
	// skipClean omits the Debian clean target.
	skipClean bool
	// dryRun prohibits all mutation.
	dryRun bool
}

// resolveRequest applies defaults and validates every caller-controlled value.
func resolveRequest(request Request) (resolvedRequest, error) {
	root, err := resolveRepositoryRoot(request.RepositoryRoot)
	if err != nil {
		return resolvedRequest{}, err
	}
	gitURL := request.GitURL
	if gitURL == "" {
		gitURL = DefaultGitURL
	}
	if err := validateGitURL(gitURL); err != nil {
		return resolvedRequest{}, err
	}
	gitRef := request.GitBranch
	if gitRef == "" {
		gitRef = DefaultGitBranch
	}
	if err := validateGitRef(gitRef); err != nil {
		return resolvedRequest{}, err
	}
	if request.Jobs < 0 || request.Jobs > maximumBuildJobs {
		return resolvedRequest{}, fmt.Errorf("kernel build jobs must be between 0 and %d", maximumBuildJobs)
	}
	workName := request.WorkDirectory
	if workName == "" {
		workName = DefaultWorkDirectory
	}
	outputName := request.OutputDirectory
	if outputName == "" {
		outputName = DefaultOutputDirectory
	}
	work, err := resolveContainedDirectory(root, workName, "work")
	if err != nil {
		return resolvedRequest{}, err
	}
	output, err := resolveContainedDirectory(root, outputName, "output")
	if err != nil {
		return resolvedRequest{}, err
	}
	if pathsOverlap(work, output) {
		return resolvedRequest{}, errors.New("kernel build work and output directories must not overlap")
	}
	if err := requireNewOutput(output); err != nil {
		return resolvedRequest{}, err
	}
	return resolvedRequest{
		repositoryRoot:  root,
		workDirectory:   work,
		outputDirectory: output,
		gitURL:          gitURL,
		gitRef:          gitRef,
		jobs:            request.Jobs,
		resetSource:     request.ResetSource,
		skipClean:       request.SkipClean,
		dryRun:          request.DryRun,
	}, nil
}

// resolveRepositoryRoot returns an explicit directory, the nearest OE checkout,
// or the current directory for a standalone released CLI.
func resolveRepositoryRoot(configured string) (string, error) {
	selected := configured
	if strings.TrimSpace(selected) == "" {
		current, err := os.Getwd()
		if err != nil {
			return "", fmt.Errorf("resolve current build directory: %w", err)
		}
		selected = nearestRepositoryRoot(current)
	}
	absolute, err := filepath.Abs(selected)
	if err != nil {
		return "", fmt.Errorf("resolve kernel build repository root: %w", err)
	}
	canonical, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return "", fmt.Errorf("resolve kernel build repository root %s: %w", absolute, err)
	}
	canonical = filepath.Clean(canonical)
	if canonical == filepath.VolumeName(canonical)+string(filepath.Separator) {
		return "", errors.New("kernel build repository root must not be a filesystem root")
	}
	if err := validateMountPath(canonical, "repository root"); err != nil {
		return "", err
	}
	info, err := os.Lstat(canonical)
	if err != nil {
		return "", fmt.Errorf("inspect kernel build repository root: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", fmt.Errorf("kernel build repository root is not a canonical directory: %s", canonical)
	}
	return canonical, nil
}

// nearestRepositoryRoot walks upwards for the CLI module marker and otherwise
// returns the starting directory for standalone use.
func nearestRepositoryRoot(start string) string {
	start = filepath.Clean(start)
	for current := start; ; current = filepath.Dir(current) {
		marker := filepath.Join(current, "cli", "linux-armer", "go.mod")
		if info, err := os.Stat(marker); err == nil && info.Mode().IsRegular() {
			return current
		}
		parent := filepath.Dir(current)
		if parent == current {
			return start
		}
	}
}

// resolveContainedDirectory validates a repository-relative path without
// creating it or traversing a symbolic link.
func resolveContainedDirectory(root, relative, label string) (string, error) {
	if strings.TrimSpace(relative) == "" || filepath.IsAbs(relative) {
		return "", fmt.Errorf("kernel build %s directory must be a non-empty repository-relative path", label)
	}
	clean := filepath.Clean(relative)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("kernel build %s directory escapes or aliases the repository root", label)
	}
	target := filepath.Join(root, clean)
	relativeCheck, err := filepath.Rel(root, target)
	if err != nil || relativeCheck == ".." || strings.HasPrefix(relativeCheck, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("kernel build %s directory escapes the repository root", label)
	}
	if err := validateMountPath(target, label+" directory"); err != nil {
		return "", err
	}
	if err := validateRoute(root, target); err != nil {
		return "", fmt.Errorf("validate kernel build %s directory: %w", label, err)
	}
	return target, nil
}

// validateRoute rejects symbolic-link or non-directory components below root.
func validateRoute(root, target string) error {
	relative, err := filepath.Rel(root, target)
	if err != nil {
		return err
	}
	current := root
	for _, component := range strings.Split(relative, string(filepath.Separator)) {
		if component == "" || component == "." {
			continue
		}
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("path contains symbolic link: %s", current)
		}
		if !info.IsDir() {
			return fmt.Errorf("path component is not a directory: %s", current)
		}
	}
	return nil
}

// requireNewOutput refuses any existing output so unrelated or stale packages
// are never deleted or mixed into a new bundle.
func requireNewOutput(path string) error {
	_, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect kernel build output directory: %w", err)
	}
	return fmt.Errorf("kernel build output directory must not already exist: %s", path)
}

// pathsOverlap reports equality or ancestor relationships between two paths.
func pathsOverlap(left, right string) bool {
	leftToRight, leftErr := filepath.Rel(left, right)
	rightToLeft, rightErr := filepath.Rel(right, left)
	return leftErr == nil && (leftToRight == "." || (leftToRight != ".." && !strings.HasPrefix(leftToRight, ".."+string(filepath.Separator)))) ||
		rightErr == nil && (rightToLeft == "." || (rightToLeft != ".." && !strings.HasPrefix(rightToLeft, ".."+string(filepath.Separator))))
}

// validateMountPath rejects path bytes that Docker's mount argument cannot
// represent without delimiter interpretation.
func validateMountPath(path, label string) error {
	if path == "" || !utf8.ValidString(path) || strings.Contains(path, ",") {
		return fmt.Errorf("kernel build %s is empty, malformed, or contains a Docker mount delimiter", label)
	}
	for _, character := range path {
		if character < 0x20 || character == 0x7f {
			return fmt.Errorf("kernel build %s contains a control character", label)
		}
	}
	return nil
}

// validateGitURL accepts only bounded HTTPS remotes without credentials,
// queries, or fragments.
func validateGitURL(value string) error {
	if len(value) == 0 || len(value) > maximumGitURLBytes || !utf8.ValidString(value) {
		return errors.New("kernel Git URL is empty, oversized, or malformed")
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return errors.New("kernel Git URL must be an HTTPS repository without credentials, query, or fragment")
	}
	if parsed.Path == "" || parsed.Path == "/" || strings.Contains(parsed.Path, "\\") {
		return errors.New("kernel Git URL must contain a repository path")
	}
	for _, character := range value {
		if character < 0x20 || character == 0x7f {
			return errors.New("kernel Git URL contains a control character")
		}
	}
	return nil
}

// validateGitRef accepts a conservative branch or tag without ambiguous Git syntax.
func validateGitRef(value string) error {
	if len(value) == 0 || len(value) > maximumGitRefBytes || !utf8.ValidString(value) || !gitRefComponentExpression.MatchString(value) {
		return errors.New("kernel Git ref is empty, oversized, or malformed")
	}
	if strings.Contains(value, "..") || strings.Contains(value, "//") || strings.Contains(value, "@{") ||
		strings.HasSuffix(value, "/") || strings.HasSuffix(value, ".") || strings.HasSuffix(value, ".lock") {
		return errors.New("kernel Git ref contains ambiguous Git syntax")
	}
	for _, component := range strings.Split(value, "/") {
		if component == "" || strings.HasPrefix(component, ".") || strings.HasSuffix(component, ".lock") {
			return errors.New("kernel Git ref contains an unsafe path component")
		}
	}
	return nil
}

// workspaceIdentity binds the reusable Docker volume to one canonical work path.
func workspaceIdentity(root, work string) string {
	digest := sha256.Sum256([]byte(root + "\x00" + work))
	return hex.EncodeToString(digest[:])
}
