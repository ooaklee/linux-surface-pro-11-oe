package release

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
)

// Validate repeats the closed-set, provenance, pairing, and digest proofs.
func (manager *Manager) Validate(ctx context.Context, request ValidationRequest) (ValidationReceipt, error) {
	if manager == nil || len(manager.policy.sources) != 4 || len(manager.policy.artefacts) != 4 {
		return ValidationReceipt{}, errors.New("audio release validator is unavailable")
	}
	if err := ctx.Err(); err != nil {
		return ValidationReceipt{}, err
	}
	repositoryRoot, err := canonicalDirectory(request.RepositoryRoot, "repository root")
	if err != nil {
		return ValidationReceipt{}, err
	}
	directory, err := canonicalDirectory(request.Directory, "audio release directory")
	if err != nil {
		return ValidationReceipt{}, err
	}
	expected := filepath.Join(repositoryRoot, filepath.FromSlash(DefaultOutputDirectory), filepath.Base(directory))
	if directory != expected {
		return ValidationReceipt{}, errors.New("audio release directory must be a direct child of repository build/release")
	}
	manifestIdentity, err := inspectRegular(ctx, filepath.Join(directory, ManifestName), "audio release manifest", maximumManifestBytes)
	if err != nil {
		return ValidationReceipt{}, err
	}
	manifestData, err := readIdentity(ctx, manifestIdentity, maximumManifestBytes)
	if err != nil {
		return ValidationReceipt{}, err
	}
	manifest, err := decodeManifest(manifestData)
	if err != nil {
		return ValidationReceipt{}, err
	}
	canonical, err := marshalManifest(manifest)
	if err != nil {
		return ValidationReceipt{}, err
	}
	if !bytes.Equal(manifestData, canonical) {
		return ValidationReceipt{}, errors.New("audio release manifest is not canonical deterministic JSON")
	}
	if err := validateDirectory(ctx, directory, manifest, manager.policy, true); err != nil {
		return ValidationReceipt{}, err
	}
	return ValidationReceipt{Directory: directory, Manifest: manifest, Valid: true}, nil
}

// decodeManifest rejects duplicate, unknown, trailing, and over-deep JSON data.
func decodeManifest(data []byte) (Manifest, error) {
	if len(data) == 0 || int64(len(data)) > maximumManifestBytes {
		return Manifest{}, errors.New("audio release manifest is empty or outside its size limit")
	}
	if err := rejectDuplicateJSONNames(data); err != nil {
		return Manifest{}, fmt.Errorf("validate audio release manifest JSON: %w", err)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var manifest Manifest
	if err := decoder.Decode(&manifest); err != nil {
		return Manifest{}, fmt.Errorf("decode audio release manifest: %w", err)
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return Manifest{}, errors.New("audio release manifest contains multiple JSON values")
		}
		return Manifest{}, fmt.Errorf("decode trailing audio release manifest data: %w", err)
	}
	return manifest, nil
}

// rejectDuplicateJSONNames rejects repeated object fields at every bounded depth.
func rejectDuplicateJSONNames(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := walkJSONValue(decoder, 0); err != nil {
		return err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("JSON contains trailing values")
		}
		return err
	}
	return nil
}

// walkJSONValue consumes one JSON value while tracking object member names.
func walkJSONValue(decoder *json.Decoder, depth int) error {
	if depth > maximumJSONDepth {
		return errors.New("JSON nesting exceeds its limit")
	}
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delimiter, isDelimiter := token.(json.Delim)
	if !isDelimiter {
		return nil
	}
	switch delimiter {
	case '{':
		seen := make(map[string]struct{})
		for decoder.More() {
			nameToken, nameErr := decoder.Token()
			if nameErr != nil {
				return nameErr
			}
			name, ok := nameToken.(string)
			if !ok {
				return errors.New("JSON object member name is not text")
			}
			if _, exists := seen[name]; exists {
				return fmt.Errorf("duplicate JSON member %q", name)
			}
			seen[name] = struct{}{}
			if err := walkJSONValue(decoder, depth+1); err != nil {
				return err
			}
		}
		closing, closeErr := decoder.Token()
		if closeErr != nil || closing != json.Delim('}') {
			return errors.New("JSON object is not closed")
		}
	case '[':
		for decoder.More() {
			if err := walkJSONValue(decoder, depth+1); err != nil {
				return err
			}
		}
		closing, closeErr := decoder.Token()
		if closeErr != nil || closing != json.Delim(']') {
			return errors.New("JSON array is not closed")
		}
	default:
		return errors.New("JSON contains an unexpected delimiter")
	}
	return nil
}

// inspectPolicyArtefacts proves all four staged payloads match compiled pins.
func inspectPolicyArtefacts(ctx context.Context, directory string, selected policy) ([]FileRecord, error) {
	artefacts := make([]FileRecord, 0, len(selected.artefacts))
	for _, expected := range selected.artefacts {
		identity, err := inspectRegular(ctx, filepath.Join(directory, expected.name), "audio artefact "+expected.name, maximumSourceBytes)
		if err != nil {
			return nil, err
		}
		if identity.record.SHA256 != expected.sha256 || identity.record.Size != expected.size {
			return nil, fmt.Errorf("audio artefact differs from compiled v19c identity: %s", expected.name)
		}
		artefacts = append(artefacts, identity.record)
	}
	return artefacts, nil
}

// validateDirectory verifies the exact seven files and every deterministic record.
func validateDirectory(ctx context.Context, directory string, manifest Manifest, selected policy, requireTagDirectory bool) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if manifest.SchemaVersion != SchemaVersion || manifest.Status != "verified-local-preparation" || manifest.Tag != selected.tag ||
		(requireTagDirectory && manifest.Tag != filepath.Base(directory)) || manifest.RemoteMutation || !manifest.ProtectedVendorBytes {
		return errors.New("audio release manifest header is inconsistent")
	}
	generation, err := parseKernelPair(manifest.KernelTag, manifest.KernelABI)
	if err != nil || generation != manifest.KernelGeneration {
		return errors.New("audio release manifest kernel pairing is inconsistent")
	}
	if err := validateSourceProvenance(manifest.Source, selected); err != nil {
		return err
	}
	if err := validateClosedSet(directory); err != nil {
		return err
	}
	artefacts, err := inspectPolicyArtefacts(ctx, directory, selected)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(artefacts, manifest.Artefacts) {
		return errors.New("audio release manifest artefacts differ from staged bytes or order")
	}
	checksumData, err := renderChecksums(artefacts)
	if err != nil {
		return err
	}
	expectedChecksum := inspectData(ChecksumName, checksumData)
	if expectedChecksum.SHA256 != selected.checksum.sha256 || expectedChecksum.Size != selected.checksum.size {
		return errors.New("audio checksum policy is internally inconsistent")
	}
	checksumDataOnDisk, checksumRecord, err := readRegularData(ctx, filepath.Join(directory, ChecksumName), maximumTextBytes)
	if err != nil {
		return err
	}
	if !bytes.Equal(checksumDataOnDisk, checksumData) || checksumRecord != expectedChecksum {
		return errors.New("audio release SHA256SUMS differs from its deterministic contract")
	}
	notesDataOnDisk, notesRecord, err := readRegularData(ctx, filepath.Join(directory, NotesName), maximumTextBytes)
	if err != nil {
		return err
	}
	expectedNotes := renderNotes(manifest)
	if !bytes.Equal(notesDataOnDisk, expectedNotes) || notesRecord != inspectData(NotesName, expectedNotes) {
		return errors.New("audio release notes differ from their deterministic contract")
	}
	expectedGenerated := []FileRecord{expectedChecksum, inspectData(NotesName, expectedNotes)}
	if !reflect.DeepEqual(manifest.GeneratedFiles, expectedGenerated) {
		return errors.New("audio release generated-file records are incomplete or out of order")
	}
	return nil
}

// validateSourceProvenance checks path-free pins and deterministic source ordering.
func validateSourceProvenance(source SourceProvenance, selected policy) error {
	if source.Release != selected.sourceRelease || source.Revision != selected.sourceRevision || source.ChecksumManifest.Name != ChecksumName ||
		!digestExpression.MatchString(source.ChecksumManifest.SHA256) || source.ChecksumManifest.Size <= 0 || len(source.Inputs) != len(selected.sources) ||
		len(source.ValidatedChecksums) == 0 || len(source.ValidatedChecksums) > maximumSourceChecksumEntries {
		return errors.New("audio source provenance header is inconsistent")
	}
	topologyAuthenticated := false
	for index, input := range source.Inputs {
		spec := selected.sources[index]
		if input.Role != spec.role || input.File.Name != filepath.Base(filepath.FromSlash(spec.relativePath)) || input.File.SHA256 != spec.sha256 || input.File.Size <= 0 ||
			(spec.expectedSize > 0 && input.File.Size != spec.expectedSize) {
			return errors.New("audio source input provenance differs from compiled v19c pins")
		}
	}
	for index, record := range source.ValidatedChecksums {
		if !safePortableName(record.Name) || !digestExpression.MatchString(record.SHA256) || record.Size <= 0 ||
			(index > 0 && source.ValidatedChecksums[index-1].Name >= record.Name) {
			return errors.New("audio source checksum records are malformed or not uniquely sorted")
		}
		if record.Name == filepath.Base(filepath.FromSlash(selected.sources[0].relativePath)) && record.SHA256 == selected.sources[0].sha256 && record.Size == selected.sources[0].expectedSize {
			topologyAuthenticated = true
		}
	}
	if !topologyAuthenticated {
		return errors.New("audio source checksum provenance does not authenticate the FullIO topology")
	}
	return nil
}

// validateClosedSet rejects missing, extra, linked, nested, or non-regular entries.
func validateClosedSet(directory string) error {
	expected := map[string]struct{}{
		TopologyName: {}, CardUCMName: {}, HiFiUCMName: {}, MatcherName: {},
		ChecksumName: {}, NotesName: {}, ManifestName: {},
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	if len(entries) != len(expected) {
		return fmt.Errorf("audio release contains %d entries, want %d", len(entries), len(expected))
	}
	for _, entry := range entries {
		if _, allowed := expected[entry.Name()]; !allowed {
			return fmt.Errorf("audio release contains unknown entry: %s", entry.Name())
		}
		info, err := os.Lstat(filepath.Join(directory, entry.Name()))
		if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return fmt.Errorf("audio release entry is not a real regular file: %s", entry.Name())
		}
	}
	return nil
}

// readRegularData returns stable bounded bytes and their portable identity.
func readRegularData(ctx context.Context, path string, maximum int64) ([]byte, FileRecord, error) {
	identity, err := inspectRegular(ctx, path, filepath.Base(path), maximum)
	if err != nil {
		return nil, FileRecord{}, err
	}
	data, err := readIdentity(ctx, identity, maximum)
	if err != nil {
		return nil, FileRecord{}, err
	}
	return data, identity.record, nil
}

// sortedFileRecords returns a defensive lexical copy for test comparisons.
func sortedFileRecords(records []FileRecord) []FileRecord {
	result := append([]FileRecord(nil), records...)
	sort.Slice(result, func(first, second int) bool { return result[first].Name < result[second].Name })
	return result
}
