package cli

import (
	"testing"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/manager"
)

// TestDescribeWizardKernel verifies the confirmation screen reports the exact
// local, latest, or tagged kernel selection without claiming premature
// validation.
func TestDescribeWizardKernel(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		request manager.CreateImageRequest
		want    string
	}{
		{
			name: "local bundle",
			request: manager.CreateImageRequest{
				KernelDirectory: "/tmp/kernel-v19",
				KernelRelease:   "ignored-release",
			},
			want: "local bundle /tmp/kernel-v19 (validated before building)",
		},
		{
			name:    "implicit latest release",
			request: manager.CreateImageRequest{},
			want:    "latest linux-armer release (verified before building)",
		},
		{
			name: "explicit latest release",
			request: manager.CreateImageRequest{
				KernelRelease: "latest",
			},
			want: "latest linux-armer release (verified before building)",
		},
		{
			name: "tagged release",
			request: manager.CreateImageRequest{
				KernelRelease: "sp11-v19",
			},
			want: "release sp11-v19 (verified before building)",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if got := describeWizardKernel(test.request); got != test.want {
				t.Fatalf("describeWizardKernel() = %q, want %q", got, test.want)
			}
		})
	}
}
