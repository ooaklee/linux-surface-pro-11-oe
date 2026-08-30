package companion

import (
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/artifact"
	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	userspacecatalog "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/catalog"
)

// Absent returns a valid explicit manifest record for an image that deliberately
// omits the optional companion bundle.
func Absent(reason string) imagecontract.CompanionBundleRecord {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		reason = OmissionReasonNotRequested
	}
	return imagecontract.CompanionBundleRecord{
		Included:  false,
		Root:      ISOFilesystemRoot,
		Reason:    reason,
		Userspace: []imagecontract.OfflineUserspaceRecord{},
	}
}

// FlattenArtifacts returns defensive copies of every declared companion
// artefact in category order for finished-image extraction and validation.
func FlattenArtifacts(record imagecontract.CompanionBundleRecord) []imagecontract.ArtifactRecord {
	if !record.Included {
		return nil
	}
	artifacts := make([]imagecontract.ArtifactRecord, 0)
	if record.Executable != nil {
		artifacts = append(artifacts, record.Executable.Artifact)
	}
	if record.SourceArchive != nil {
		artifacts = append(artifacts, *record.SourceArchive)
	}
	artifacts = append(artifacts, record.Catalogues...)
	artifacts = append(artifacts, record.Licences...)
	for _, userspace := range record.Userspace {
		artifacts = append(artifacts, userspace.Artifacts...)
	}
	return artifacts
}

// ValidateRecord checks the complete included-or-absent companion schema,
// portable layout, deterministic ordering, policy, and artefact uniqueness.
func ValidateRecord(record imagecontract.CompanionBundleRecord) error {
	if record.Root != ISOFilesystemRoot {
		return fmt.Errorf("companion root must be %q", ISOFilesystemRoot)
	}
	if record.Userspace == nil {
		return errors.New("companion userspace must be an explicit JSON array")
	}
	if !record.Included {
		return validateAbsentRecord(record)
	}
	if record.Reason != "" {
		return errors.New("included companion bundle must not declare an omission reason")
	}
	if record.Tool == nil {
		return errors.New("included companion bundle has no tool identity")
	}
	if err := validateToolIdentity(*record.Tool); err != nil {
		return err
	}
	if record.Executable == nil {
		return errors.New("included companion bundle has no executable")
	}
	if err := validateExecutableRecord(*record.Executable); err != nil {
		return err
	}
	if record.SourceArchive == nil {
		return errors.New("included companion bundle has no source archive")
	}
	expectedSourcePath := path.Join(
		ISOFilesystemRoot, "source", fmt.Sprintf("linux-armer_%s_source.tar.gz", record.Tool.Version),
	)
	if record.SourceArchive.Path != expectedSourcePath {
		return fmt.Errorf("companion source archive path must be %q", expectedSourcePath)
	}
	if err := validateCatalogueRecords(record.Catalogues); err != nil {
		return err
	}
	if err := validateLicenceRecords(record.ProjectLicence, record.Licences); err != nil {
		return err
	}
	if err := validateUserspaceRecords(record.Userspace); err != nil {
		return err
	}
	artifacts := FlattenArtifacts(record)
	if err := imagecontract.ValidateArtifactRecords(artifacts); err != nil {
		return fmt.Errorf("validate companion artefacts: %w", err)
	}
	return nil
}

// ValidateDirectory proves that an extracted host directory corresponding to
// /sp11/companion contains exactly the files declared by record.
func ValidateDirectory(record imagecontract.CompanionBundleRecord, companionDirectory string) error {
	if err := ValidateRecord(record); err != nil {
		return err
	}
	if err := validateCanonicalAbsolutePath(companionDirectory, "extracted companion directory"); err != nil {
		return err
	}
	if !record.Included {
		if _, err := os.Lstat(companionDirectory); errors.Is(err, os.ErrNotExist) {
			return nil
		} else if err != nil {
			return fmt.Errorf("inspect omitted companion directory: %w", err)
		}
		return errors.New("companion directory exists although the manifest marks it absent")
	}
	if err := validateDirectory(companionDirectory, "extracted companion directory"); err != nil {
		return err
	}
	rootInfo, err := os.Lstat(companionDirectory)
	if err != nil {
		return err
	}
	if err := validateExtractedDirectoryMode(rootInfo, "."); err != nil {
		return err
	}
	expected, allowedDirectories, err := expectedDirectoryMembers(record)
	if err != nil {
		return err
	}
	seen := make(map[string]bool, len(expected))
	err = filepath.WalkDir(companionDirectory, func(hostPath string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if hostPath == companionDirectory {
			return nil
		}
		relative, err := filepath.Rel(companionDirectory, hostPath)
		if err != nil {
			return err
		}
		portable := filepath.ToSlash(relative)
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("extracted companion path must not be a symbolic link: %s", portable)
		}
		if entry.IsDir() {
			if !allowedDirectories[portable] {
				return fmt.Errorf("extracted companion contains undeclared directory %q", portable)
			}
			info, err := entry.Info()
			if err != nil {
				return err
			}
			if err := validateExtractedDirectoryMode(info, portable); err != nil {
				return err
			}
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("extracted companion path is not a regular file: %s", portable)
		}
		recordItem, found := expected[portable]
		if !found {
			return fmt.Errorf("extracted companion contains undeclared file %q", portable)
		}
		if info.Size() != recordItem.Size {
			return fmt.Errorf("extracted companion file %q is %d bytes, expected %d", portable, info.Size(), recordItem.Size)
		}
		digest, err := artifact.HashFile(hostPath)
		if err != nil {
			return err
		}
		if digest != recordItem.SHA256 {
			return fmt.Errorf("extracted companion file %q SHA-256 is %s, expected %s", portable, digest, recordItem.SHA256)
		}
		seen[portable] = true
		return nil
	})
	if err != nil {
		return err
	}
	if len(seen) != len(expected) {
		missing := make([]string, 0)
		for name := range expected {
			if !seen[name] {
				missing = append(missing, name)
			}
		}
		sort.Strings(missing)
		return fmt.Errorf("extracted companion is missing declared files: %s", strings.Join(missing, ", "))
	}
	executablePath := filepath.Join(companionDirectory, filepath.FromSlash(executableRelativePath))
	info, err := os.Lstat(executablePath)
	if err != nil {
		return err
	}
	if info.Mode().Perm() != 0o755 || info.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
		return fmt.Errorf("extracted companion executable mode is %04o, expected 0755", info.Mode().Perm())
	}
	return validateAArch64ELF(executablePath)
}

// validateExtractedDirectoryMode requires deterministic traversal permissions
// and rejects set-ID or sticky metadata on every extracted companion directory.
func validateExtractedDirectoryMode(info os.FileInfo, portablePath string) error {
	if info.Mode().Perm() != 0o755 || info.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
		return fmt.Errorf("extracted companion directory %q mode is %04o, expected 0755 without special bits", portablePath, info.Mode().Perm())
	}
	return nil
}

// validateAbsentRecord rejects contradictory payload fields on an explicit
// omission record while requiring a concise human-readable reason.
func validateAbsentRecord(record imagecontract.CompanionBundleRecord) error {
	if record.Reason != OmissionReasonNotRequested {
		return fmt.Errorf("absent companion bundle reason must be %q", OmissionReasonNotRequested)
	}
	if record.Tool != nil || record.Executable != nil || record.SourceArchive != nil ||
		record.ProjectLicence != "" || len(record.Catalogues) != 0 || len(record.Licences) != 0 || len(record.Userspace) != 0 {
		return errors.New("absent companion bundle must not declare payload metadata")
	}
	return nil
}

// validateToolIdentity checks flat release metadata and one canonical UTC
// RFC3339 build timestamp suitable for both filenames and linker flags.
func validateToolIdentity(record imagecontract.ToolIdentityRecord) error {
	if err := validateFlatName(record.Version, "companion tool version"); err != nil {
		return err
	}
	if err := validateFlatName(record.Commit, "companion tool commit"); err != nil {
		return err
	}
	buildTime, err := time.Parse(time.RFC3339Nano, record.BuildDate)
	if err != nil || buildTime.UTC().Format(time.RFC3339Nano) != record.BuildDate {
		return errors.New("companion tool build date must be a canonical UTC RFC3339 timestamp")
	}
	return nil
}

// validateExecutableRecord checks fixed platform metadata and the executable's
// canonical path before host-byte validation occurs.
func validateExecutableRecord(record imagecontract.ExecutableArtifactRecord) error {
	expectedPath := path.Join(ISOFilesystemRoot, executableRelativePath)
	if record.Artifact.Path != expectedPath {
		return fmt.Errorf("companion executable path must be %q", expectedPath)
	}
	if record.OperatingSystem != "linux" || record.Architecture != "arm64" || record.Format != "ELF" || record.Mode != executableMode {
		return errors.New("companion executable must declare linux/arm64 ELF mode 0755")
	}
	return nil
}

// validateCatalogueRecords requires exactly the two maintained catalogue paths
// in deterministic lexical order.
func validateCatalogueRecords(records []imagecontract.ArtifactRecord) error {
	expected := []string{
		path.Join(ISOFilesystemRoot, "catalogues", imageCatalogueName),
		path.Join(ISOFilesystemRoot, "catalogues", userspaceCatalogueName),
	}
	sort.Strings(expected)
	if len(records) != len(expected) {
		return fmt.Errorf("companion bundle must declare exactly %d catalogues", len(expected))
	}
	for index := range expected {
		if records[index].Path != expected[index] {
			return fmt.Errorf("companion catalogue %d path must be %q", index, expected[index])
		}
	}
	return nil
}

// validateLicenceRecords checks policy vocabulary, immediate portable paths,
// lexical order, and agreement between declared status and discovered terms.
func validateLicenceRecords(projectLicence string, records []imagecontract.ArtifactRecord) error {
	if projectLicence != projectLicenceDeclared && projectLicence != projectLicenceNotDeclared {
		return fmt.Errorf("companion project licence must be %q or %q", projectLicenceDeclared, projectLicenceNotDeclared)
	}
	hasDeclaration := false
	previous := ""
	for _, record := range records {
		prefix := path.Join(ISOFilesystemRoot, "licences") + "/"
		if !strings.HasPrefix(record.Path, prefix) {
			return fmt.Errorf("companion licence path is outside %q: %s", prefix, record.Path)
		}
		name := strings.TrimPrefix(record.Path, prefix)
		if err := validateFlatName(name, "companion licence filename"); err != nil {
			return err
		}
		if previous != "" && record.Path <= previous {
			return errors.New("companion licence records are not in unique lexical order")
		}
		previous = record.Path
		if record.Size == 0 {
			return fmt.Errorf("companion licence or notice must not be empty: %s", record.Path)
		}
		kind, recognised := projectDocumentKind(name)
		if !recognised {
			return fmt.Errorf("companion licence inventory contains unrecognised document %q", name)
		}
		if kind != "notice" {
			hasDeclaration = true
		}
	}
	if projectLicence == projectLicenceDeclared && !hasDeclaration {
		return errors.New("companion project licence is declared but no licence or copying document is inventoried")
	}
	if projectLicence == projectLicenceNotDeclared && hasDeclaration {
		return errors.New("companion project licence is not-declared but redistribution terms are inventoried")
	}
	return nil
}

// validateUserspaceRecords checks eligible redistribution policy, exact roots,
// flat membership, and deterministic component and artefact ordering.
func validateUserspaceRecords(records []imagecontract.OfflineUserspaceRecord) error {
	previousBundle := ""
	for _, record := range records {
		if err := validateFlatName(record.Component, "offline userspace component"); err != nil {
			return err
		}
		if err := validateFlatName(record.Release, "offline userspace release"); err != nil {
			return err
		}
		if err := validateOfflineUserspaceRecordContract(record); err != nil {
			return err
		}
		if record.Component != IPTSDOfflineComponentID {
			return fmt.Errorf("offline userspace component %q is not approved by compiled companion policy", record.Component)
		}
		key := record.Component + "\x00" + record.Release
		if previousBundle != "" && key <= previousBundle {
			return errors.New("offline userspace records are not in unique lexical order")
		}
		previousBundle = key
		if record.Redistribution != string(userspacecatalog.RedistributionAllowed) &&
			record.Redistribution != string(userspacecatalog.RedistributionSourceRequired) {
			return fmt.Errorf("offline userspace component %q has ineligible redistribution policy %q", record.Component, record.Redistribution)
		}
		expectedRoot := path.Join(ISOFilesystemRoot, "userspace", record.Component, record.Release)
		if record.Root != expectedRoot {
			return fmt.Errorf("offline userspace root must be %q", expectedRoot)
		}
		if len(record.Artifacts) == 0 {
			return fmt.Errorf("offline userspace component %q has no artefacts", record.Component)
		}
		hasReceipt := false
		previousPath := ""
		for _, artifactRecord := range record.Artifacts {
			if path.Dir(artifactRecord.Path) != expectedRoot {
				return fmt.Errorf("offline userspace artefact is outside %q: %s", expectedRoot, artifactRecord.Path)
			}
			if err := validateFlatName(path.Base(artifactRecord.Path), "offline userspace filename"); err != nil {
				return err
			}
			if previousPath != "" && artifactRecord.Path <= previousPath {
				return errors.New("offline userspace artefacts are not in unique lexical order")
			}
			previousPath = artifactRecord.Path
			if path.Base(artifactRecord.Path) == userspaceReceiptName {
				hasReceipt = true
			}
		}
		if !hasReceipt {
			return fmt.Errorf("offline userspace component %q has no portable receipt", record.Component)
		}
	}
	return nil
}

// expectedDirectoryMembers converts portable manifest paths into a closed set
// relative to the extracted companion root and its necessary directories.
func expectedDirectoryMembers(record imagecontract.CompanionBundleRecord) (map[string]imagecontract.ArtifactRecord, map[string]bool, error) {
	expected := make(map[string]imagecontract.ArtifactRecord)
	directories := make(map[string]bool)
	prefix := ISOFilesystemRoot + "/"
	for _, artifactRecord := range FlattenArtifacts(record) {
		if !strings.HasPrefix(artifactRecord.Path, prefix) {
			return nil, nil, fmt.Errorf("companion artefact is outside root: %s", artifactRecord.Path)
		}
		relative := strings.TrimPrefix(artifactRecord.Path, prefix)
		if relative == "" || path.Clean(relative) != relative {
			return nil, nil, fmt.Errorf("companion artefact has invalid root-relative path: %s", artifactRecord.Path)
		}
		expected[relative] = artifactRecord
		for directory := path.Dir(relative); directory != "."; directory = path.Dir(directory) {
			directories[directory] = true
		}
	}
	return expected, directories, nil
}
