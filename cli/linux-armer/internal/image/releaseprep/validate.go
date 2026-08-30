package releaseprep

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"

	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
)

// partSequenceReader opens one declared part at a time and verifies bytes while read.
type partSequenceReader struct {
	// ctx supplies cancellation between bounded reads.
	ctx context.Context
	// directory contains the closed release set.
	directory string
	// records are the expected part identities in stream order.
	records []FileRecord
	// index identifies the current record.
	index int
	// file is the active regular file.
	file *os.File
	// info binds the active filesystem object.
	info os.FileInfo
	// hash receives active-part bytes.
	hash hashState
	// size counts active-part bytes.
	size int64
	// complete reports that all declared part bytes reached EOF.
	complete bool
}

// Read streams and validates one declared part sequence without broad file opens.
func (reader *partSequenceReader) Read(data []byte) (int, error) {
	if err := reader.ctx.Err(); err != nil {
		return 0, err
	}
	for {
		if reader.file == nil {
			if reader.index >= len(reader.records) {
				reader.complete = true
				return 0, io.EOF
			}
			if err := reader.open(); err != nil {
				return 0, err
			}
		}
		count, readErr := reader.file.Read(data)
		if count > 0 {
			written, hashErr := reader.hash.Write(data[:count])
			reader.size += int64(written)
			if hashErr != nil {
				return count, hashErr
			}
			if written != count {
				return count, io.ErrShortWrite
			}
		}
		if errors.Is(readErr, io.EOF) {
			if err := reader.closeAndVerify(); err != nil {
				return count, err
			}
			if count > 0 {
				return count, nil
			}
			continue
		}
		if readErr != nil {
			return count, readErr
		}
		return count, nil
	}
}

// open opens and binds the next non-symbolic-link part.
func (reader *partSequenceReader) open() error {
	path := filepath.Join(reader.directory, reader.records[reader.index].Name)
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("compressed part is not a regular file: %s", reader.records[reader.index].Name)
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	opened, err := file.Stat()
	if err != nil || !os.SameFile(info, opened) {
		_ = file.Close()
		return errors.New("compressed part changed while opening")
	}
	reader.file = file
	reader.info = info
	reader.hash = sha256.New()
	reader.size = 0
	return nil
}

// closeAndVerify closes one consumed part and checks its complete identity.
func (reader *partSequenceReader) closeAndVerify() error {
	record := reader.records[reader.index]
	closeErr := reader.file.Close()
	current, statErr := os.Lstat(filepath.Join(reader.directory, record.Name))
	reader.file = nil
	if err := errors.Join(closeErr, statErr); err != nil {
		return err
	}
	if current.Mode()&os.ModeSymlink != 0 || !os.SameFile(reader.info, current) ||
		reader.size != record.Size || hex.EncodeToString(reader.hash.Sum(nil)) != record.SHA256 {
		return fmt.Errorf("compressed part changed while reading: %s", record.Name)
	}
	reader.index++
	reader.info = nil
	reader.hash = nil
	reader.size = 0
	return nil
}

// Close closes any active part after completion or failure.
func (reader *partSequenceReader) Close() error {
	if reader == nil || reader.file == nil {
		return nil
	}
	err := reader.file.Close()
	reader.file = nil
	return err
}

// Validate verifies a closed release directory without changing it.
func (manager *Manager) Validate(ctx context.Context, directory string) (ValidationResult, error) {
	if manager == nil || manager.Compressor == nil {
		return ValidationResult{}, errors.New("image release manager dependencies are incomplete")
	}
	canonical, err := canonicalDirectory(directory, "image release directory")
	if err != nil {
		return ValidationResult{}, err
	}
	manifest, err := manager.validateDirectory(ctx, canonical)
	if err != nil {
		return ValidationResult{Directory: canonical, Manifest: manifest, Valid: false}, err
	}
	return ValidationResult{Directory: canonical, Manifest: manifest, Valid: true}, nil
}

// validateDirectory enforces the exact files, records, and decompressed image identity.
func (manager *Manager) validateDirectory(ctx context.Context, directory string) (Manifest, error) {
	if err := ctx.Err(); err != nil {
		return Manifest{}, err
	}
	manifestIdentity, err := inspectRegular(ctx, filepath.Join(directory, ReleaseManifestName), "image release manifest", maximumJSONBytes)
	if err != nil {
		return Manifest{}, err
	}
	manifestData, err := readIdentity(ctx, manifestIdentity, maximumJSONBytes)
	if err != nil {
		return Manifest{}, err
	}
	var manifest Manifest
	if err := decodeStrictJSON(manifestData, &manifest); err != nil {
		return Manifest{}, fmt.Errorf("decode image release manifest: %w", err)
	}
	if err := validateReleaseManifest(manifest); err != nil {
		return Manifest{}, err
	}
	canonicalManifest, err := encodeJSON(manifest)
	if err != nil || !bytes.Equal(canonicalManifest, manifestData) {
		return Manifest{}, errors.Join(errors.New("image release manifest is not canonical deterministic JSON"), err)
	}
	expected := map[string]struct{}{
		ReleaseManifestName: {}, ChecksumName: {}, NotesName: {}, manifest.ImageManifest.Name: {},
	}
	for _, part := range manifest.Parts {
		expected[part.Name] = struct{}{}
	}
	if err := requireExactDirectory(directory, expected); err != nil {
		return Manifest{}, err
	}
	checksumIdentity, err := inspectRegular(ctx, filepath.Join(directory, ChecksumName), ChecksumName, maximumTextBytes)
	if err != nil {
		return Manifest{}, err
	}
	checksumData, err := readIdentity(ctx, checksumIdentity, maximumTextBytes)
	if err != nil {
		return Manifest{}, err
	}
	checksums, err := parseChecksums(checksumData)
	if err != nil {
		return Manifest{}, err
	}
	if len(checksums) != len(expected)-1 {
		return Manifest{}, errors.New("SHA256SUMS must cover every release file except itself")
	}
	records := make([]FileRecord, 0, len(checksums))
	identities := make(map[string]regularIdentity, len(checksums))
	for name := range expected {
		if name == ChecksumName {
			continue
		}
		maximum := maximumTextBytes
		if strings.Contains(name, ".part-") {
			maximum = HostedAssetLimitBytes
		}
		identity, err := inspectRegular(ctx, filepath.Join(directory, name), "release file "+name, maximum)
		if err != nil {
			return Manifest{}, err
		}
		if checksums[name] != identity.record.SHA256 {
			return Manifest{}, fmt.Errorf("SHA256SUMS does not match %s", name)
		}
		records = append(records, identity.record)
		identities[name] = identity
	}
	if !bytes.Equal(renderChecksums(records), checksumData) {
		return Manifest{}, errors.New("SHA256SUMS is not in canonical lexical order")
	}
	notesData, err := readIdentity(ctx, identities[NotesName], maximumTextBytes)
	if err != nil {
		return Manifest{}, err
	}
	if !bytes.Equal(renderNotes(manifest), notesData) {
		return Manifest{}, errors.New("release notes differ from the manifest-derived contract")
	}
	if err := validateDeclaredRecords(records, manifest); err != nil {
		return Manifest{}, err
	}
	sidecarData, err := readIdentity(ctx, identities[manifest.ImageManifest.Name], maximumJSONBytes)
	if err != nil {
		return Manifest{}, err
	}
	sidecar, err := imagecontract.DecodeManifest(bytes.NewReader(sidecarData))
	if err != nil || !reflect.DeepEqual(sidecar, manifest.ImageContract) {
		return Manifest{}, errors.Join(errors.New("copied image manifest differs from the embedded release contract"), err)
	}
	if err := manager.validateCompressedImage(ctx, directory, manifest); err != nil {
		return Manifest{}, err
	}
	return manifest, nil
}

// validateReleaseManifest checks all path-free semantic invariants.
func validateReleaseManifest(manifest Manifest) error {
	if manifest.SchemaVersion != SchemaVersion || !safeReleaseName(manifest.ReleaseName) || manifest.RemoteMutation {
		return errors.New("image release manifest has an unsupported identity or remote-mutation claim")
	}
	if err := validateFileRecord(manifest.Image); err != nil {
		return fmt.Errorf("invalid image record: %w", err)
	}
	if !strings.HasSuffix(strings.ToLower(manifest.Image.Name), ".iso") || len(manifest.Image.Name) > 200 {
		return errors.New("release image name is not a bounded .iso basename")
	}
	if err := validateFileRecord(manifest.ImageManifest); err != nil {
		return fmt.Errorf("invalid image manifest record: %w", err)
	}
	if manifest.ImageManifest.Name != manifest.Image.Name+".manifest.json" {
		return errors.New("image manifest sidecar name is not paired with the ISO")
	}
	if err := validateImageContract(manifest.ImageContract); err != nil {
		return err
	}
	if !reflect.DeepEqual(manifest.ImageCreation.Output, manifest.Image) || manifest.ImageCreation.Operation != "image.create" ||
		manifest.ImageCreation.SchemaVersion != 1 || len(manifest.ImageCreation.Records) != len(expectedImageSteps) {
		return errors.New("path-free image creation provenance is incomplete")
	}
	for index, record := range manifest.ImageCreation.Records {
		if record.StepID != expectedImageSteps[index] || record.CompletedAt.IsZero() {
			return fmt.Errorf("path-free image creation step %d is invalid", index+1)
		}
		previous := ""
		for _, digest := range record.Digests {
			if !safePortablePath(digest.Name) || !digestExpression.MatchString(digest.SHA256) || digest.Name <= previous {
				return fmt.Errorf("path-free image creation step %s has invalid digest evidence", record.StepID)
			}
			previous = digest.Name
		}
	}
	if !manifest.StructuralValidation.Valid || manifest.StructuralValidation.Layout != manifest.ImageContract.Layout ||
		manifest.StructuralValidation.Adapter != manifest.ImageContract.Adapter ||
		manifest.StructuralValidation.KernelABI != manifest.ImageContract.KernelBundle.ABI || len(manifest.StructuralValidation.Checks) == 0 {
		return errors.New("release structural evidence differs from the image contract")
	}
	expectedDeviceTrees := make([]string, 0, len(manifest.ImageContract.KernelBundle.DeviceTrees))
	for _, deviceTree := range manifest.ImageContract.KernelBundle.DeviceTrees {
		expectedDeviceTrees = append(expectedDeviceTrees, deviceTree.Device)
	}
	sort.Strings(expectedDeviceTrees)
	if !reflect.DeepEqual(manifest.StructuralValidation.DeviceTrees, expectedDeviceTrees) {
		return errors.New("release structural device-tree evidence differs from the image contract")
	}
	seenChecks := make(map[string]struct{}, len(manifest.StructuralValidation.Checks))
	for _, check := range manifest.StructuralValidation.Checks {
		if !safeReleaseName(check.Name) || !check.Passed {
			return errors.New("release structural evidence contains a failed or unsafe check")
		}
		if _, exists := seenChecks[check.Name]; exists {
			return fmt.Errorf("release structural evidence contains duplicate check %q", check.Name)
		}
		seenChecks[check.Name] = struct{}{}
	}
	if err := validateCompression(manifest.Compression); err != nil {
		return err
	}
	if err := validateFileRecord(manifest.CompressedArchive); err != nil {
		return fmt.Errorf("invalid compressed archive record: %w", err)
	}
	if manifest.CompressedArchive.Name != manifest.Image.Name+".zst" || manifest.PartSizeBytes <= 0 ||
		manifest.PartSizeBytes >= HostedAssetLimitBytes || len(manifest.Parts) == 0 || len(manifest.Parts) > maximumPartCount {
		return errors.New("release compressed archive policy is invalid")
	}
	var total int64
	for index, part := range manifest.Parts {
		if err := validateFileRecord(part); err != nil {
			return err
		}
		expected := fmt.Sprintf("%s.part-%04d", manifest.CompressedArchive.Name, index)
		if part.Name != expected || part.Size <= 0 || part.Size > manifest.PartSizeBytes || part.Size >= HostedAssetLimitBytes {
			return fmt.Errorf("compressed part %d violates its name or size contract", index)
		}
		if index < len(manifest.Parts)-1 && part.Size != manifest.PartSizeBytes {
			return fmt.Errorf("compressed part %d is short before the final part", index)
		}
		if total > maximumImageBytes-part.Size {
			return errors.New("compressed archive size overflows its release bound")
		}
		total += part.Size
	}
	if total != manifest.CompressedArchive.Size {
		return errors.New("compressed part sizes do not equal the archive size")
	}
	return nil
}

// validateFileRecord checks one canonical portable file identity.
func validateFileRecord(record FileRecord) error {
	if !safePortableName(record.Name) || !digestExpression.MatchString(record.SHA256) || record.Size <= 0 {
		return errors.New("file record has an unsafe name, digest, or size")
	}
	return nil
}

// validateDeclaredRecords binds checksummed files to the manifest payload records.
func validateDeclaredRecords(records []FileRecord, manifest Manifest) error {
	byName := make(map[string]FileRecord, len(records))
	for _, record := range records {
		byName[record.Name] = record
	}
	if !reflect.DeepEqual(byName[manifest.ImageManifest.Name], manifest.ImageManifest) {
		return errors.New("copied image-manifest identity differs from the release manifest")
	}
	for _, part := range manifest.Parts {
		if !reflect.DeepEqual(byName[part.Name], part) {
			return fmt.Errorf("compressed part identity differs from the release manifest: %s", part.Name)
		}
	}
	return nil
}

// validateCompressedImage proves archive and reconstructed ISO identities in one stream.
func (manager *Manager) validateCompressedImage(ctx context.Context, directory string, manifest Manifest) error {
	reader := &partSequenceReader{ctx: ctx, directory: directory, records: manifest.Parts}
	defer reader.Close()
	compressedHasher := sha256.New()
	rawHasher := sha256.New()
	rawCounter := &countingHashWriter{hash: rawHasher, maximum: manifest.Image.Size}
	if err := manager.Compressor.Decompress(ctx, io.TeeReader(reader, compressedHasher), rawCounter); err != nil {
		return err
	}
	if !reader.complete {
		if _, err := copyContext(ctx, io.Discard, reader, maximumImageBytes); err != nil {
			return err
		}
	}
	if !reader.complete || hex.EncodeToString(compressedHasher.Sum(nil)) != manifest.CompressedArchive.SHA256 ||
		rawCounter.size != manifest.Image.Size || hex.EncodeToString(rawHasher.Sum(nil)) != manifest.Image.SHA256 {
		return errors.New("compressed parts do not reconstruct the declared image identity")
	}
	return nil
}

// sortedRecords returns records in lexical order for stable comparisons.
func sortedRecords(records []FileRecord) []FileRecord {
	result := append([]FileRecord(nil), records...)
	sort.Slice(result, func(left, right int) bool { return result[left].Name < result[right].Name })
	return result
}
