package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image/releaseprep"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image/ubuntu"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// newImageReleaseCommand groups local-only release preparation and validation.
func (a *application) newImageReleaseCommand() *cobra.Command {
	command := &cobra.Command{
		Use:   "release",
		Short: "Prepare and validate local split image-release assets",
		Long:  "Prepare or validate a closed, checksummed set of split zstd image assets without publishing or changing any remote service.",
		Args:  cobra.NoArgs,
	}
	command.AddCommand(a.newImageReleasePrepareCommand(), a.newImageReleaseValidateCommand())
	return command
}

// newImageReleasePrepareCommand prepares one fresh, atomic local release directory.
func (a *application) newImageReleasePrepareCommand() *cobra.Command {
	request := releaseprep.Request{}
	var asJSON bool
	command := &cobra.Command{
		Use:   "prepare <iso>",
		Short: "Prepare deterministic split zstd assets from one validated ISO",
		Args:  cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			request.ImagePath = args[0]
			manager := releaseprep.New(ubuntu.NewValidator(nil), releaseprep.NewZstdCompressor(platform.ExecRunner{}))
			if request.DryRun {
				operationPlan, err := manager.Plan(command.Context(), request)
				if err != nil {
					return err
				}
				if asJSON {
					return a.writeJSON(operationPlan)
				}
				_, err = fmt.Fprintf(a.out,
					"image release plan validated; no files or remote services changed\nimage: %s\nSHA-256: %s\noutput: %s\npart limit: %d bytes\n",
					operationPlan.ImagePath, operationPlan.Image.SHA256, operationPlan.OutputDirectory, operationPlan.PartSizeBytes)
				return err
			}
			receipt, err := manager.Prepare(command.Context(), request)
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(receipt)
			}
			_, err = fmt.Fprintf(a.out,
				"local image release prepared and validated\ndirectory: %s\nimage SHA-256: %s\nparts: %d\nremote publication: not performed\n",
				receipt.Plan.OutputDirectory, receipt.Manifest.Image.SHA256, len(receipt.Manifest.Parts))
			return err
		},
	}
	command.Flags().StringVar(&request.RepositoryRoot, "repository-root", ".", "support repository root containing the source ISO")
	command.Flags().StringVar(&request.ReleaseName, "release-name", "", "portable release name (defaults to the ISO stem)")
	command.Flags().StringVar(&request.OutputDirectory, "out-dir", "", "fresh build/release/<release-name> directory")
	command.Flags().Int64Var(&request.PartSizeBytes, "part-size-bytes", releaseprep.DefaultPartSizeBytes, "maximum compressed part size below the hosted asset limit")
	command.Flags().BoolVar(&request.DryRun, "dry-run", false, "verify the local plan without structural validation, compression, or writes")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable plan or receipt JSON")
	return command
}

// newImageReleaseValidateCommand verifies a closed release and reconstructed ISO digest.
func (a *application) newImageReleaseValidateCommand() *cobra.Command {
	var asJSON bool
	command := &cobra.Command{
		Use:   "validate <release-directory>",
		Short: "Validate exact release files and the reconstructed ISO identity",
		Args:  cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			manager := releaseprep.New(ubuntu.NewValidator(nil), releaseprep.NewZstdCompressor(platform.ExecRunner{}))
			result, err := manager.Validate(command.Context(), args[0])
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(result)
			}
			_, err = fmt.Fprintf(a.out,
				"image release is valid\ndirectory: %s\nimage: %s\nSHA-256: %s\nparts: %d\n",
				result.Directory, result.Manifest.Image.Name, result.Manifest.Image.SHA256, len(result.Manifest.Parts))
			return err
		},
	}
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable validation JSON")
	return command
}
