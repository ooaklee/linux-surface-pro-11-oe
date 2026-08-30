package companion

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"path"

	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	userspacepolicy "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/policy"
	userspacerelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/release"
)

// iptsdOfflineReleaseContract is the package-private compiled trust anchor used
// by staging and manifest validation. Tests may replace it with an exact local
// fixture without exposing a production policy override.
var iptsdOfflineReleaseContract = userspacepolicy.IPTSDRelease()

// validateOfflineBundleIdentity prevents a mutable catalogue from redirecting
// the approved component identifier to another publisher or release tag.
func validateOfflineBundleIdentity(bundle userspacerelease.Bundle) error {
	return iptsdOfflineReleaseContract.ValidateIdentity(bundle)
}

// validateOfflineBundleArtifacts prevents a mutable catalogue from changing
// the approved release's filenames, byte lengths, or digests.
func validateOfflineBundleArtifacts(files []userspacerelease.File) error {
	return iptsdOfflineReleaseContract.ValidateArtifacts(files)
}

// validateOfflineBundleReceipt requires the canonical downloader receipt so
// its recorded digest also binds the otherwise implicit repository identity.
func validateOfflineBundleReceipt(content []byte) error {
	expected, err := iptsdOfflineReleaseContract.PortableReceipt()
	if err != nil {
		return fmt.Errorf("construct immutable userspace receipt: %w", err)
	}
	if !bytes.Equal(content, expected) {
		return fmt.Errorf("portable userspace receipt does not match the immutable %s release contract", iptsdOfflineReleaseContract.Component)
	}
	return nil
}

// validateOfflineUserspaceRecordContract proves that one outer image-manifest
// record names exactly the compiled release and every expected artefact,
// including the canonical receipt that binds its repository identity.
func validateOfflineUserspaceRecordContract(record imagecontract.OfflineUserspaceRecord) error {
	contract := iptsdOfflineReleaseContract
	if record.Component != contract.Component {
		return fmt.Errorf("offline userspace component %q is not approved by compiled companion policy", record.Component)
	}
	if record.Release != contract.Tag {
		return fmt.Errorf("offline userspace release is %q, expected immutable release %q", record.Release, contract.Tag)
	}
	expectedRoot := path.Join(ISOFilesystemRoot, "userspace", contract.Component, contract.Tag)
	if record.Root != expectedRoot {
		return fmt.Errorf("offline userspace root must be %q", expectedRoot)
	}
	expected := make(map[string]userspacepolicy.Artifact, len(contract.Artifacts)+1)
	for _, artifact := range contract.Artifacts {
		expected[artifact.Name] = artifact
	}
	receipt, err := contract.PortableReceipt()
	if err != nil {
		return fmt.Errorf("construct immutable userspace receipt: %w", err)
	}
	receiptDigest := sha256.Sum256(receipt)
	expected[userspaceReceiptName] = userspacepolicy.Artifact{
		Name: userspaceReceiptName, SHA256: hex.EncodeToString(receiptDigest[:]), Size: int64(len(receipt)),
	}
	if len(record.Artifacts) != len(expected) {
		return fmt.Errorf("offline userspace record contains %d artefacts, expected %d", len(record.Artifacts), len(expected))
	}
	seen := make(map[string]bool, len(record.Artifacts))
	for _, artifactRecord := range record.Artifacts {
		name := path.Base(artifactRecord.Path)
		artifact, found := expected[name]
		if !found {
			return fmt.Errorf("offline userspace record contains unexpected artefact %q", name)
		}
		if seen[name] {
			return fmt.Errorf("offline userspace record repeats artefact %q", name)
		}
		seen[name] = true
		if artifactRecord.Path != path.Join(expectedRoot, name) {
			return fmt.Errorf("offline userspace artefact path must be %q", path.Join(expectedRoot, name))
		}
		if artifactRecord.SHA256 != artifact.SHA256 || artifactRecord.Size != artifact.Size {
			return fmt.Errorf("offline userspace artefact %q disagrees with immutable release metadata", name)
		}
	}
	return nil
}
