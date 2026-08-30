// Package caspermedia models Ubuntu Casper's live-media discovery contract.
package caspermedia

import (
	"errors"
	"fmt"

	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
)

const (
	// DirectHybridStrategy identifies an ISO written directly to removable media.
	DirectHybridStrategy = "direct-hybrid"
	// Protocol identifies the Ubuntu Casper live-boot implementation.
	Protocol = "casper"
	// MediumIdentityPath is the ISO member Casper compares while scanning media.
	MediumIdentityPath = ".disk/casper-uuid-generic"
	// InitramfsIdentityPath is the generated initramfs member holding the same UUID.
	InitramfsIdentityPath = "conf/uuid.conf"
	// MediumIdentityRole identifies the evidence read from the direct ISO.
	MediumIdentityRole = "medium-identity"
	// InitramfsIdentityRole identifies the evidence embedded by mkinitramfs.
	InitramfsIdentityRole = "initramfs-identity"
	// ISOFilesystemScope identifies evidence stored in the ISO 9660 filesystem.
	ISOFilesystemScope = "iso-filesystem"
	// InitramfsScope identifies evidence stored inside the live initramfs.
	InitramfsScope = "initramfs"
)

// Contract records how a direct Ubuntu ISO binds its generated initramfs to
// the physical medium that contains the live filesystem.
type Contract struct {
	// Strategy identifies the outer media-discovery layout.
	Strategy string
	// Protocol identifies the distribution live-boot implementation.
	Protocol string
	// MediumPath is the ISO-relative identity marker examined by Casper.
	MediumPath string
	// InitramfsPath is the initramfs-relative identity consumed by Casper.
	InitramfsPath string
	// UUID is the canonical identity that must be equal at both paths.
	UUID string
}

// NewDirectHybrid parses a generated initramfs UUID and returns the complete
// direct-media Casper contract that must be written into the ISO.
func NewDirectHybrid(data []byte) (Contract, error) {
	uuid, err := ParseUUID(data)
	if err != nil {
		return Contract{}, err
	}
	return Contract{
		Strategy:      DirectHybridStrategy,
		Protocol:      Protocol,
		MediumPath:    MediumIdentityPath,
		InitramfsPath: InitramfsIdentityPath,
		UUID:          uuid,
	}, nil
}

// ParseUUID accepts one canonical lowercase UUID and rejects additional data,
// uppercase spellings, path-like values, and malformed Casper identities.
func ParseUUID(data []byte) (string, error) {
	if len(data) == 37 && data[36] == '\n' {
		data = data[:36]
	}
	value := string(data)
	if value == "" {
		return "", errors.New("Casper UUID is empty")
	}
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return "", fmt.Errorf("Casper UUID %q is not canonical", value)
	}
	for index, character := range value {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			continue
		}
		if character < '0' || character > '9' && character < 'a' || character > 'f' {
			return "", fmt.Errorf("Casper UUID %q is not lowercase hexadecimal", value)
		}
	}
	return value, nil
}

// Validate verifies that every field of a Casper contract describes the
// supported direct-hybrid identity pairing.
func (c Contract) Validate() error {
	if c.Strategy != DirectHybridStrategy {
		return fmt.Errorf("unsupported Casper media strategy %q", c.Strategy)
	}
	if c.Protocol != Protocol {
		return fmt.Errorf("unsupported live-boot protocol %q", c.Protocol)
	}
	if c.MediumPath != MediumIdentityPath || c.InitramfsPath != InitramfsIdentityPath {
		return errors.New("Casper identity paths do not match the direct-hybrid contract")
	}
	if _, err := ParseUUID([]byte(c.UUID)); err != nil {
		return err
	}
	return nil
}

// DiscoveryRecord converts a valid Casper contract and its immutable medium
// marker into the generic evidence shape shared by all image adapters.
func (c Contract) DiscoveryRecord(medium imagecontract.ArtifactRecord) (imagecontract.MediaDiscoveryRecord, error) {
	if err := c.Validate(); err != nil {
		return imagecontract.MediaDiscoveryRecord{}, err
	}
	if medium.Path != MediumIdentityPath {
		return imagecontract.MediaDiscoveryRecord{}, fmt.Errorf("Casper medium artifact path is %q, expected %q", medium.Path, MediumIdentityPath)
	}
	if err := imagecontract.ValidateArtifactRecord(medium); err != nil {
		return imagecontract.MediaDiscoveryRecord{}, fmt.Errorf("validate Casper medium artifact: %w", err)
	}
	return imagecontract.MediaDiscoveryRecord{
		Strategy: c.Strategy,
		Protocol: c.Protocol,
		Evidence: []imagecontract.MediaDiscoveryEvidence{
			{
				Role: MediumIdentityRole, Scope: ISOFilesystemScope,
				Path: c.MediumPath, Value: c.UUID, Artifact: &medium,
			},
			{
				Role: InitramfsIdentityRole, Scope: InitramfsScope,
				Path: c.InitramfsPath, Value: c.UUID,
			},
		},
	}, nil
}

// FromDiscoveryRecord validates generic manifest evidence as the exact direct
// Ubuntu Casper contract and returns its independently hashed medium marker.
func FromDiscoveryRecord(record imagecontract.MediaDiscoveryRecord) (Contract, imagecontract.ArtifactRecord, error) {
	if record.Strategy != DirectHybridStrategy || record.Protocol != Protocol {
		return Contract{}, imagecontract.ArtifactRecord{}, fmt.Errorf(
			"unsupported Casper discovery strategy %q and protocol %q", record.Strategy, record.Protocol)
	}
	if len(record.Evidence) != 2 {
		return Contract{}, imagecontract.ArtifactRecord{}, fmt.Errorf("Casper discovery evidence has %d records, expected 2", len(record.Evidence))
	}
	var medium imagecontract.ArtifactRecord
	var mediumValue, initramfsValue string
	for _, evidence := range record.Evidence {
		switch evidence.Role {
		case MediumIdentityRole:
			if evidence.Scope != ISOFilesystemScope || evidence.Path != MediumIdentityPath || evidence.Artifact == nil {
				return Contract{}, imagecontract.ArtifactRecord{}, errors.New("Casper medium identity evidence is incomplete")
			}
			medium = *evidence.Artifact
			mediumValue = evidence.Value
		case InitramfsIdentityRole:
			if evidence.Scope != InitramfsScope || evidence.Path != InitramfsIdentityPath || evidence.Artifact != nil {
				return Contract{}, imagecontract.ArtifactRecord{}, errors.New("Casper initramfs identity evidence is incomplete")
			}
			initramfsValue = evidence.Value
		default:
			return Contract{}, imagecontract.ArtifactRecord{}, fmt.Errorf("unsupported Casper discovery evidence role %q", evidence.Role)
		}
	}
	if mediumValue == "" || initramfsValue == "" || mediumValue != initramfsValue {
		return Contract{}, imagecontract.ArtifactRecord{}, errors.New("Casper discovery evidence identities do not agree")
	}
	contract, err := NewDirectHybrid([]byte(mediumValue))
	if err != nil {
		return Contract{}, imagecontract.ArtifactRecord{}, err
	}
	if medium.Path != MediumIdentityPath {
		return Contract{}, imagecontract.ArtifactRecord{}, fmt.Errorf("Casper medium artifact path is %q, expected %q", medium.Path, MediumIdentityPath)
	}
	if err := imagecontract.ValidateArtifactRecord(medium); err != nil {
		return Contract{}, imagecontract.ArtifactRecord{}, fmt.Errorf("validate Casper medium artifact: %w", err)
	}
	return contract, medium, nil
}

// Matches reports whether medium and initramfs identity files contain the
// same valid UUID and returns the parsed contract when they agree.
func Matches(medium, initramfs []byte) (Contract, error) {
	mediumUUID, err := ParseUUID(medium)
	if err != nil {
		return Contract{}, fmt.Errorf("parse Casper medium UUID: %w", err)
	}
	initramfsUUID, err := ParseUUID(initramfs)
	if err != nil {
		return Contract{}, fmt.Errorf("parse Casper initramfs UUID: %w", err)
	}
	if mediumUUID != initramfsUUID {
		return Contract{}, fmt.Errorf("Casper media UUID %s does not match initramfs UUID %s", mediumUUID, initramfsUUID)
	}
	return NewDirectHybrid(initramfs)
}
