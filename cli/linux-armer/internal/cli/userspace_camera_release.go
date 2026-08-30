package cli

import (
	"context"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	camerarelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/release"
)

// cameraReleaseManager is the delivery layer's narrow local-release capability.
type cameraReleaseManager interface {
	// Prepare validates and atomically creates one local release directory.
	Prepare(context.Context, camerarelease.Request) (camerarelease.Receipt, error)
	// Validate repeats static, digest-pinned proof for one local release directory.
	Validate(context.Context, camerarelease.ValidationRequest) (camerarelease.ValidationReceipt, error)
}

// newUserspaceCameraReleaseCommand groups local-only preparation and validation.
func (a *application) newUserspaceCameraReleaseCommand(manager cameraReleaseManager) *cobra.Command {
	if manager == nil {
		manager = camerarelease.New(nil)
	}
	command := &cobra.Command{
		Use:   "release",
		Short: "Prepare or validate a closed local camera release",
		Long:  "Prepare or validate a closed local camera release. These commands never create a tag, upload an artefact, or change a remote service.",
		Args:  cobra.NoArgs,
	}
	command.AddCommand(
		a.newUserspaceCameraReleasePrepareCommand(manager),
		a.newUserspaceCameraReleaseValidateCommand(manager),
	)
	return command
}

// newUserspaceCameraReleasePrepareCommand builds the local preparation command.
func (a *application) newUserspaceCameraReleasePrepareCommand(manager cameraReleaseManager) *cobra.Command {
	request := camerarelease.Request{RepositoryRoot: "."}
	var asJSON bool
	command := &cobra.Command{
		Use:   "prepare",
		Short: "Prepare a new eleven-file camera release directory locally",
		Args:  cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			if strings.TrimSpace(request.ArtifactsDirectory) == "" {
				return fmt.Errorf("native camera build directory is required; pass --from")
			}
			if strings.TrimSpace(request.Tag) == "" || strings.TrimSpace(request.KernelTag) == "" || strings.TrimSpace(request.KernelABI) == "" {
				return fmt.Errorf("release tag, paired kernel tag, and paired kernel ABI are required")
			}
			if strings.TrimSpace(request.ExpectedBuildAuthoritySHA256) == "" {
				return fmt.Errorf("trusted native camera build authority is required; pass --build-authority-sha256")
			}
			receipt, err := manager.Prepare(command.Context(), request)
			if asJSON {
				if writeErr := a.writeJSON(receipt); writeErr != nil {
					return writeErr
				}
				return err
			}
			if writeErr := a.writeCameraReleasePreparation(receipt); writeErr != nil {
				return writeErr
			}
			return err
		},
	}
	command.Flags().StringVar(&request.RepositoryRoot, "repository-root", ".", "OE repository root containing authenticated camera inputs")
	command.Flags().StringVar(&request.ArtifactsDirectory, "from", "", "exact eight-file native camera build directory")
	command.Flags().StringVar(&request.OutputDirectory, "output-dir", "", "repository-relative local release parent")
	command.Flags().StringVar(&request.Tag, "tag", "", "new local camera release tag")
	command.Flags().StringVar(&request.KernelTag, "kernel-tag", "", "explicit paired kernel release tag")
	command.Flags().StringVar(&request.KernelABI, "kernel-abi", "", "explicit paired installed qcom-x1e ABI")
	command.Flags().StringVar(&request.ExpectedBuildAuthoritySHA256, "build-authority-sha256", "", "trusted authority digest printed by the native camera build")
	command.Flags().BoolVar(&request.DryRun, "dry-run", false, "show the local policy without package commands or filesystem mutation")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// writeCameraReleasePreparation renders a concise local-only preparation result.
func (a *application) writeCameraReleasePreparation(receipt camerarelease.Receipt) error {
	if receipt.Plan.DryRun {
		if _, err := fmt.Fprintf(a.out, "camera release dry run\ntag: %s\npaired kernel: %s\npaired ABI: %s\nbuild authority SHA-256: %s\nremote mutation: false\n", receipt.Plan.Tag, receipt.Plan.KernelTag, receipt.Plan.KernelABI, receipt.Plan.ExpectedBuildAuthoritySHA256); err != nil {
			return err
		}
		if !receipt.Plan.Executable {
			_, err := fmt.Fprintf(a.out, "execution unavailable: %s\n", receipt.Plan.ExecutionBlocker)
			return err
		}
		return nil
	}
	if !receipt.Published || receipt.Manifest == nil {
		_, err := fmt.Fprintln(a.out, "camera release was not prepared")
		return err
	}
	_, err := fmt.Fprintf(a.out, "prepared closed local camera release\ndirectory: %s\nfiles: 11\nmanifest: %s\nauthority SHA-256: %s\nremote mutation: false\n", receipt.Plan.ReleaseDirectory, camerarelease.ManifestName, receipt.AuthoritySHA256)
	return err
}

// newUserspaceCameraReleaseValidateCommand builds the local validation command.
func (a *application) newUserspaceCameraReleaseValidateCommand(manager cameraReleaseManager) *cobra.Command {
	var repositoryRoot string
	var authoritySHA256 string
	var asJSON bool
	command := &cobra.Command{
		Use:   "validate <release-directory>",
		Short: "Repeat static, digest-pinned camera release proofs",
		Args:  cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			if strings.TrimSpace(authoritySHA256) == "" {
				return fmt.Errorf("trusted camera release authority is required; pass --authority-sha256")
			}
			receipt, err := manager.Validate(command.Context(), camerarelease.ValidationRequest{
				RepositoryRoot:          repositoryRoot,
				Directory:               args[0],
				ExpectedAuthoritySHA256: authoritySHA256,
			})
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(receipt)
			}
			_, err = fmt.Fprintf(a.out, "camera release valid\ntag: %s\ndirectory: %s\nauthority SHA-256: %s\nfiles: 11\nremote mutation: false\n", receipt.Manifest.Tag, receipt.Directory, authoritySHA256)
			return err
		},
	}
	command.Flags().StringVar(&repositoryRoot, "repository-root", ".", "OE repository root containing authenticated camera inputs")
	command.Flags().StringVar(&authoritySHA256, "authority-sha256", "", "trusted authority digest printed by camera release preparation")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}
