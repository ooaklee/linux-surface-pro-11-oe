package cli

import (
	"bytes"
	"strings"
	"testing"

	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/manager"
)

// TestWriteImageCreateResultWarnsAboutUndeclaredCompanionLicence verifies the
// human-readable result warns only when an included bundle lacks licence terms.
func TestWriteImageCreateResultWarnsAboutUndeclaredCompanionLicence(t *testing.T) {
	t.Parallel()

	for _, testCase := range []struct {
		name          string
		companion     imagecontract.CompanionBundleRecord
		warningWanted bool
	}{
		{
			name: "included without declared licence",
			companion: imagecontract.CompanionBundleRecord{
				Included: true, ProjectLicence: "not-declared",
			},
			warningWanted: true,
		},
		{
			name: "included with declared licence",
			companion: imagecontract.CompanionBundleRecord{
				Included: true, ProjectLicence: "declared",
			},
		},
		{
			name: "absent bundle",
			companion: imagecontract.CompanionBundleRecord{
				Included: false, ProjectLicence: "not-declared",
			},
		},
	} {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			var output bytes.Buffer
			app := &application{out: &output}
			result := manager.CreateImageResult{}
			result.Image.CompanionBundle = testCase.companion

			if err := app.writeImageCreateResult(result); err != nil {
				t.Fatalf("writeImageCreateResult() error = %v", err)
			}
			warningPresent := strings.Contains(output.String(), "project licence is not declared")
			if warningPresent != testCase.warningWanted {
				t.Fatalf("licence warning present = %v, want %v\n%s", warningPresent, testCase.warningWanted, output.String())
			}
		})
	}
}
