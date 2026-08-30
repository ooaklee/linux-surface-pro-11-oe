package cli

import (
	"context"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	audiorelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/audio/release"
)

// audioReleaseManager is the delivery layer's narrow local-release capability.
type audioReleaseManager interface {
	// Prepare validates pinned sources and atomically creates one local release.
	Prepare(context.Context, audiorelease.Request) (audiorelease.Receipt, error)
	// Validate repeats every closed-directory and immutable-identity proof.
	Validate(context.Context, audiorelease.ValidationRequest) (audiorelease.ValidationReceipt, error)
}

// newUserspaceAudioCommand groups FullIO v19c audio companion operations.
func (a *application) newUserspaceAudioCommand(manager audioReleaseManager) *cobra.Command {
	command := &cobra.Command{
		Use:   "audio",
		Short: "Manage Surface Pro 11 FullIO audio support",
		Args:  cobra.NoArgs,
	}
	command.AddCommand(a.newUserspaceAudioReleaseCommand(manager))
	return command
}

// newUserspaceAudioReleaseCommand groups local-only preparation and validation.
func (a *application) newUserspaceAudioReleaseCommand(manager audioReleaseManager) *cobra.Command {
	if manager == nil {
		manager = audiorelease.New()
	}
	command := &cobra.Command{
		Use:   "release",
		Short: "Prepare or validate a closed local FullIO v19c audio release",
		Long:  "Prepare or validate a closed local FullIO v19c audio release. These commands never create a tag, upload an artefact, or change a remote service.",
		Args:  cobra.NoArgs,
	}
	command.AddCommand(
		a.newUserspaceAudioReleasePrepareCommand(manager),
		a.newUserspaceAudioReleaseValidateCommand(manager),
	)
	return command
}

// newUserspaceAudioReleasePrepareCommand builds the explicit local preparation command.
func (a *application) newUserspaceAudioReleasePrepareCommand(manager audioReleaseManager) *cobra.Command {
	request := audiorelease.Request{RepositoryRoot: "."}
	var asJSON bool
	command := &cobra.Command{
		Use:   "prepare",
		Short: "Prepare the reviewed seven-file FullIO v19c release locally",
		Args:  cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			if strings.TrimSpace(request.SourceRoot) == "" {
				return fmt.Errorf("audio source root is required; pass --source-root")
			}
			if strings.TrimSpace(request.Tag) == "" || strings.TrimSpace(request.KernelTag) == "" || strings.TrimSpace(request.KernelABI) == "" {
				return fmt.Errorf("release tag, paired kernel tag, and paired kernel ABI are required")
			}
			receipt, err := manager.Prepare(command.Context(), request)
			if asJSON {
				if writeErr := a.writeJSON(receipt); writeErr != nil {
					return writeErr
				}
				return err
			}
			if err != nil {
				return err
			}
			return a.writeAudioReleasePreparation(receipt)
		},
	}
	command.Flags().StringVar(&request.RepositoryRoot, "repository-root", ".", "OE repository root containing the fixed build/release destination")
	command.Flags().StringVar(&request.SourceRoot, "source-root", "", "explicit SP11X1e-audio checkout containing the pinned v19c deployment")
	command.Flags().StringVar(&request.Tag, "tag", "", "exact reviewed local audio release tag")
	command.Flags().StringVar(&request.KernelTag, "kernel-tag", "", "explicit paired Surface kernel release tag")
	command.Flags().StringVar(&request.KernelABI, "kernel-abi", "", "explicit paired installed qcom-x1e ABI")
	command.Flags().BoolVar(&request.DryRun, "dry-run", false, "validate inputs and show the local policy without filesystem publication")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// writeAudioReleasePreparation renders one concise local-only result.
func (a *application) writeAudioReleasePreparation(receipt audiorelease.Receipt) error {
	if receipt.Plan.DryRun {
		if _, err := fmt.Fprintf(a.out, "audio release dry run\ntag: %s\npaired kernel: %s\npaired ABI: %s\nsource release: %s\nremote mutation: false\n", receipt.Plan.Tag, receipt.Plan.KernelTag, receipt.Plan.KernelABI, receipt.Plan.Source.Release); err != nil {
			return err
		}
		if !receipt.Plan.Executable {
			_, err := fmt.Fprintf(a.out, "execution unavailable: %s\n", receipt.Plan.ExecutionBlocker)
			return err
		}
		return nil
	}
	if !receipt.Published || receipt.Manifest == nil {
		return fmt.Errorf("audio release was not prepared")
	}
	_, err := fmt.Fprintf(a.out, "prepared closed local FullIO v19c audio release\ndirectory: %s\nartefacts: 7\nmanifest: %s\nremote mutation: false\n", receipt.Plan.ReleaseDirectory, audiorelease.ManifestName)
	return err
}

// newUserspaceAudioReleaseValidateCommand builds the closed-set validation command.
func (a *application) newUserspaceAudioReleaseValidateCommand(manager audioReleaseManager) *cobra.Command {
	var repositoryRoot string
	var asJSON bool
	command := &cobra.Command{
		Use:   "validate <release-directory>",
		Short: "Repeat the FullIO v19c source, pairing, and artefact proofs",
		Args:  cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			receipt, err := manager.Validate(command.Context(), audiorelease.ValidationRequest{
				RepositoryRoot: repositoryRoot,
				Directory:      args[0],
			})
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(receipt)
			}
			_, err = fmt.Fprintf(a.out, "FullIO v19c audio release valid\ntag: %s\ndirectory: %s\nartefacts: 7\nremote mutation: false\n", receipt.Manifest.Tag, receipt.Directory)
			return err
		},
	}
	command.Flags().StringVar(&repositoryRoot, "repository-root", ".", "OE repository root containing the fixed build/release destination")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}
