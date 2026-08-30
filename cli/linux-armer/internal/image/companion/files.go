package companion

import (
	"debug/elf"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/artifact"
	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
)

var (
	// portableFlatNamePattern accepts conservative cross-platform filenames and
	// metadata tokens without path or traversal semantics.
	portableFlatNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+~-]*$`)
	// maintainedRootFiles lists source, configuration, catalogue, and public
	// documentation files deliberately admitted to the source archive.
	maintainedRootFiles = []string{
		".gitignore",
		".goreleaser.yaml",
		".tool-versions",
		"CHANGELOG.md",
		"README.md",
		"catalog.go",
		"go.mod",
		"go.sum",
		imageCatalogueName,
		userspaceCatalogueName,
	}
	// maintainedSourceDirectories select the file suffixes admitted beneath each
	// source or documentation directory.
	maintainedSourceDirectories = map[string]string{
		"cmd":      ".go",
		"docs":     ".md",
		"internal": ".go",
	}
)

// collectSourceFiles returns a deterministic allow-listed source tree while
// rejecting links and special files in every maintained directory.
func collectSourceFiles(sourceRoot string) ([]sourceFile, error) {
	for _, required := range []string{"go.mod", "catalog.go", filepath.Join("cmd", "linux-armer", "main.go")} {
		if err := validateRegularFile(filepath.Join(sourceRoot, required), "required linux-armer source file"); err != nil {
			return nil, err
		}
	}
	files := make([]sourceFile, 0)
	seen := make(map[string]bool)
	add := func(absolutePath, portablePath string) {
		portablePath = filepath.ToSlash(portablePath)
		if !seen[portablePath] {
			seen[portablePath] = true
			files = append(files, sourceFile{absolutePath: absolutePath, portablePath: portablePath})
		}
	}
	for _, name := range maintainedRootFiles {
		absolutePath := filepath.Join(sourceRoot, name)
		if _, err := os.Lstat(absolutePath); errors.Is(err, os.ErrNotExist) {
			continue
		} else if err != nil {
			return nil, fmt.Errorf("inspect maintained source file %s: %w", name, err)
		}
		if err := validateRegularFile(absolutePath, "maintained linux-armer source file"); err != nil {
			return nil, err
		}
		add(absolutePath, name)
	}
	directoryNames := make([]string, 0, len(maintainedSourceDirectories))
	for name := range maintainedSourceDirectories {
		directoryNames = append(directoryNames, name)
	}
	sort.Strings(directoryNames)
	for _, directoryName := range directoryNames {
		directory := filepath.Join(sourceRoot, directoryName)
		if _, err := os.Lstat(directory); errors.Is(err, os.ErrNotExist) {
			continue
		} else if err != nil {
			return nil, fmt.Errorf("inspect maintained source directory %s: %w", directoryName, err)
		}
		if err := filepath.WalkDir(directory, func(itemPath string, entry os.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if entry.Type()&os.ModeSymlink != 0 {
				return fmt.Errorf("maintained source path must not be a symbolic link: %s", itemPath)
			}
			if entry.IsDir() {
				return nil
			}
			info, err := entry.Info()
			if err != nil {
				return err
			}
			if !info.Mode().IsRegular() {
				return fmt.Errorf("maintained source path is not a regular file: %s", itemPath)
			}
			if filepath.Ext(entry.Name()) != maintainedSourceDirectories[directoryName] {
				return nil
			}
			relative, err := filepath.Rel(sourceRoot, itemPath)
			if err != nil {
				return err
			}
			add(itemPath, relative)
			return nil
		}); err != nil {
			return nil, fmt.Errorf("collect maintained %s files: %w", directoryName, err)
		}
	}
	licenceFiles, _, err := discoverLicenceFiles(sourceRoot)
	if err != nil {
		return nil, err
	}
	for _, file := range licenceFiles {
		add(file.absolutePath, file.portablePath)
	}
	sort.Slice(files, func(left, right int) bool {
		return files[left].portablePath < files[right].portablePath
	})
	for index := range files {
		info, err := os.Lstat(files[index].absolutePath)
		if err != nil {
			return nil, err
		}
		digest, err := artifact.HashFile(files[index].absolutePath)
		if err != nil {
			return nil, err
		}
		files[index].sha256 = digest
		files[index].size = info.Size()
	}
	return files, nil
}

// discoverLicenceFiles finds only direct project-level licence, copying, and
// notice documents and records whether any file actually declares terms.
func discoverLicenceFiles(sourceRoot string) ([]sourceFile, string, error) {
	entries, err := os.ReadDir(sourceRoot)
	if err != nil {
		return nil, "", fmt.Errorf("read linux-armer source directory: %w", err)
	}
	files := make([]sourceFile, 0)
	declared := false
	for _, entry := range entries {
		kind, recognised := projectDocumentKind(entry.Name())
		if !recognised {
			continue
		}
		if err := validateFlatName(entry.Name(), "project licence or notice filename"); err != nil {
			return nil, "", err
		}
		absolutePath := filepath.Join(sourceRoot, entry.Name())
		if err := validateRegularFile(absolutePath, "project licence or notice file"); err != nil {
			return nil, "", err
		}
		files = append(files, sourceFile{absolutePath: absolutePath, portablePath: entry.Name()})
		if kind != "notice" {
			declared = true
		}
	}
	sort.Slice(files, func(left, right int) bool {
		return files[left].portablePath < files[right].portablePath
	})
	if declared {
		return files, projectLicenceDeclared, nil
	}
	return files, projectLicenceNotDeclared, nil
}

// projectDocumentKind recognises conventional project-level redistribution and
// notice filenames without treating similarly prefixed words as documents.
func projectDocumentKind(name string) (string, bool) {
	lower := strings.ToLower(name)
	for _, candidate := range []struct {
		prefix string
		kind   string
	}{
		{prefix: "license", kind: "licence"},
		{prefix: "licence", kind: "licence"},
		{prefix: "copying", kind: "copying"},
		{prefix: "notice", kind: "notice"},
	} {
		if lower == candidate.prefix {
			return candidate.kind, true
		}
		if strings.HasPrefix(lower, candidate.prefix) && len(lower) > len(candidate.prefix) {
			switch lower[len(candidate.prefix)] {
			case '.', '-', '_':
				return candidate.kind, true
			}
		}
	}
	return "", false
}

// validateCanonicalAbsolutePath rejects ambiguous host paths before they are
// used as trust boundaries or staging destinations.
func validateCanonicalAbsolutePath(value, label string) error {
	if value == "" || !filepath.IsAbs(value) || filepath.Clean(value) != value {
		return fmt.Errorf("%s must be a canonical absolute path", label)
	}
	return nil
}

// validateDirectory requires a canonical absolute directory whose final path
// component is not a symbolic link.
func validateDirectory(value, label string) error {
	if err := validateCanonicalAbsolutePath(value, label); err != nil {
		return err
	}
	info, err := os.Lstat(value)
	if err != nil {
		return fmt.Errorf("inspect %s: %w", label, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("%s is not a non-symlink directory: %s", label, value)
	}
	return nil
}

// validateRegularFile requires an existing regular file and explicitly rejects
// symbolic links even when their targets are ordinary files.
func validateRegularFile(value, label string) error {
	if err := validateCanonicalAbsolutePath(value, label); err != nil {
		return err
	}
	info, err := os.Lstat(value)
	if err != nil {
		return fmt.Errorf("inspect %s: %w", label, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular non-symlink file: %s", label, value)
	}
	return nil
}

// setPublishedDirectoryModes makes the companion root and every generated
// descendant directory deterministically traversable before atomic publication.
func setPublishedDirectoryModes(companionRoot string) error {
	if err := filepath.WalkDir(companionRoot, func(itemPath string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("generated companion path must not be a symbolic link: %s", itemPath)
		}
		if entry.IsDir() {
			if err := os.Chmod(itemPath, 0o755); err != nil {
				return fmt.Errorf("set generated companion directory mode: %w", err)
			}
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("generated companion path is not a regular file: %s", itemPath)
		}
		return nil
	}); err != nil {
		return fmt.Errorf("normalise published companion directories: %w", err)
	}
	return nil
}

// validateFlatName enforces one conservative portable filename component.
func validateFlatName(value, label string) error {
	if value == "" || value == "." || value == ".." || filepath.Base(value) != value ||
		strings.ContainsAny(value, `/\\`) || !portableFlatNamePattern.MatchString(value) {
		return fmt.Errorf("%s %q is not a safe flat name", label, value)
	}
	return nil
}

// copyAndRecord copies one checked source without following a final symbolic
// link, applies a fixed mode, and records the exact staged bytes.
func copyAndRecord(source, destination, portablePath string, mode os.FileMode) (imagecontract.ArtifactRecord, error) {
	if err := validateRegularFile(source, "companion source file"); err != nil {
		return imagecontract.ArtifactRecord{}, err
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return imagecontract.ArtifactRecord{}, fmt.Errorf("create companion file directory: %w", err)
	}
	input, err := os.Open(source)
	if err != nil {
		return imagecontract.ArtifactRecord{}, fmt.Errorf("open companion source file: %w", err)
	}
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		_ = input.Close()
		return imagecontract.ArtifactRecord{}, fmt.Errorf("create companion destination file: %w", err)
	}
	_, copyErr := io.Copy(output, input)
	inputCloseErr := input.Close()
	outputCloseErr := output.Close()
	if copyErr != nil || inputCloseErr != nil || outputCloseErr != nil {
		_ = os.Remove(destination)
		return imagecontract.ArtifactRecord{}, fmt.Errorf("copy companion file: %w", errors.Join(copyErr, inputCloseErr, outputCloseErr))
	}
	if err := os.Chmod(destination, mode); err != nil {
		_ = os.Remove(destination)
		return imagecontract.ArtifactRecord{}, fmt.Errorf("set companion file mode: %w", err)
	}
	return recordFile(destination, portablePath)
}

// recordFile hashes one staged regular file and validates the resulting
// portable manifest artefact before returning it.
func recordFile(hostPath, portablePath string) (imagecontract.ArtifactRecord, error) {
	if err := validateRegularFile(hostPath, "staged companion file"); err != nil {
		return imagecontract.ArtifactRecord{}, err
	}
	info, err := os.Lstat(hostPath)
	if err != nil {
		return imagecontract.ArtifactRecord{}, err
	}
	digest, err := artifact.HashFile(hostPath)
	if err != nil {
		return imagecontract.ArtifactRecord{}, err
	}
	record := imagecontract.ArtifactRecord{Path: portablePath, SHA256: digest, Size: info.Size()}
	if err := imagecontract.ValidateArtifactRecord(record); err != nil {
		return imagecontract.ArtifactRecord{}, err
	}
	return record, nil
}

// validateAArch64ELF proves that the staged executable is a little-endian
// 64-bit AArch64 executable without dynamic-loader segments.
func validateAArch64ELF(hostPath string) error {
	executable, err := elf.Open(hostPath)
	if err != nil {
		return fmt.Errorf("inspect companion executable ELF: %w", err)
	}
	defer executable.Close()
	if executable.Class != elf.ELFCLASS64 || executable.Data != elf.ELFDATA2LSB || executable.Machine != elf.EM_AARCH64 {
		return fmt.Errorf("companion executable is not a little-endian 64-bit AArch64 ELF")
	}
	if executable.Type != elf.ET_EXEC {
		return fmt.Errorf("companion executable ELF type is %s, expected an executable", executable.Type)
	}
	for _, program := range executable.Progs {
		if program.Type == elf.PT_INTERP || program.Type == elf.PT_DYNAMIC {
			return errors.New("companion executable is dynamically linked")
		}
	}
	return nil
}
