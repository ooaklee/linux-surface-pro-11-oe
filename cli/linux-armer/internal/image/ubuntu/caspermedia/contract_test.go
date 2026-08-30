package caspermedia

import (
	"strings"
	"testing"

	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
)

// TestNewDirectHybridBuildsCasperContract verifies a generated UUID expands to
// the exact direct-media identity paths understood by Ubuntu Casper.
func TestNewDirectHybridBuildsCasperContract(t *testing.T) {
	t.Parallel()

	contract, err := NewDirectHybrid([]byte("c5ef1897-ed0f-490e-b6d8-961dc41124b2\n"))
	if err != nil {
		t.Fatalf("NewDirectHybrid() error = %v", err)
	}
	if contract.Strategy != DirectHybridStrategy || contract.Protocol != Protocol ||
		contract.MediumPath != MediumIdentityPath || contract.InitramfsPath != InitramfsIdentityPath ||
		contract.UUID != "c5ef1897-ed0f-490e-b6d8-961dc41124b2" {
		t.Fatalf("NewDirectHybrid() = %#v", contract)
	}
	if err := contract.Validate(); err != nil {
		t.Fatalf("Contract.Validate() error = %v", err)
	}
}

// TestParseUUIDRejectsUnsafeValues verifies malformed, non-canonical, and
// multi-value identities cannot enter ISO paths or discovery metadata.
func TestParseUUIDRejectsUnsafeValues(t *testing.T) {
	t.Parallel()

	for _, value := range []string{
		"",
		" c5ef1897-ed0f-490e-b6d8-961dc41124b2",
		"c5ef1897-ed0f-490e-b6d8-961dc41124b2 ",
		"c5ef1897-ed0f-490e-b6d8-961dc41124b2\r\n",
		"c5ef1897-ed0f-490e-b6d8-961dc41124b2\n\n",
		"C5EF1897-ED0F-490E-B6D8-961DC41124B2",
		"c5ef1897-ed0f-490e-b6d8-961dc41124b",
		"c5ef1897-ed0f-490e-b6d8-961dc41124bg",
		"c5ef1897-ed0f-490e-b6d8-961dc41124b2\n7bda4398-0498-4564-acfe-e90dcc1c75f2",
		"../../etc/passwd",
	} {
		if _, err := ParseUUID([]byte(value)); err == nil {
			t.Errorf("ParseUUID(%q) succeeded, want error", value)
		}
	}
}

// TestMatchesRejectsDesynchronisedIdentity reproduces the failed-image
// contract and proves a source marker cannot validate a newly generated UUID.
func TestMatchesRejectsDesynchronisedIdentity(t *testing.T) {
	t.Parallel()

	_, err := Matches(
		[]byte("7bda4398-0498-4564-acfe-e90dcc1c75f2\n"),
		[]byte("c5ef1897-ed0f-490e-b6d8-961dc41124b2\n"),
	)
	if err == nil || !strings.Contains(err.Error(), "does not match") {
		t.Fatalf("Matches() error = %v, want mismatch", err)
	}
}

// TestDiscoveryRecordRoundTrip verifies Casper owns the translation between its
// strict identity pairing and the distribution-neutral manifest evidence model.
func TestDiscoveryRecordRoundTrip(t *testing.T) {
	t.Parallel()

	contract, err := NewDirectHybrid([]byte("c5ef1897-ed0f-490e-b6d8-961dc41124b2\n"))
	if err != nil {
		t.Fatal(err)
	}
	marker := imagecontract.ArtifactRecord{
		Path: MediumIdentityPath, SHA256: strings.Repeat("a", 64), Size: 37,
	}
	record, err := contract.DiscoveryRecord(marker)
	if err != nil {
		t.Fatalf("Contract.DiscoveryRecord() error = %v", err)
	}
	gotContract, gotMarker, err := FromDiscoveryRecord(record)
	if err != nil {
		t.Fatalf("FromDiscoveryRecord() error = %v", err)
	}
	if gotContract != contract || gotMarker != marker {
		t.Fatalf("round trip = %#v, %#v; want %#v, %#v", gotContract, gotMarker, contract, marker)
	}
}

// TestFromDiscoveryRecordRejectsUnexpectedEvidence verifies an adapter cannot
// silently accept an extra or differently scoped media-discovery assertion.
func TestFromDiscoveryRecordRejectsUnexpectedEvidence(t *testing.T) {
	t.Parallel()

	contract, err := NewDirectHybrid([]byte("c5ef1897-ed0f-490e-b6d8-961dc41124b2"))
	if err != nil {
		t.Fatal(err)
	}
	record, err := contract.DiscoveryRecord(imagecontract.ArtifactRecord{
		Path: MediumIdentityPath, SHA256: strings.Repeat("a", 64), Size: 37,
	})
	if err != nil {
		t.Fatal(err)
	}
	record.Evidence = append(record.Evidence, imagecontract.MediaDiscoveryEvidence{Role: "filesystem-label"})
	if _, _, err := FromDiscoveryRecord(record); err == nil || !strings.Contains(err.Error(), "expected 2") {
		t.Fatalf("FromDiscoveryRecord() error = %v, want exact-evidence error", err)
	}
}
