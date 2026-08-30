package cli

import (
	"fmt"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	kernelbuild "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/build"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/release"
)

func (a *application) newKernelCommand() *cobra.Command {
	command := &cobra.Command{
		Use:   "kernel",
		Short: "Build, download, and inspect Surface Pro 11 kernels",
		Args:  cobra.NoArgs,
	}
	releaseCommand := &cobra.Command{Use: "release", Short: "Use versioned kernel release bundles", Args: cobra.NoArgs}
	releaseCommand.AddCommand(a.newKernelReleaseListCommand(), a.newKernelReleaseDownloadCommand())
	command.AddCommand(releaseCommand, a.newKernelInspectCommand(), a.newKernelBuildCommand())
	return command
}

func (a *application) newKernelReleaseListCommand() *cobra.Command {
	var repository string
	var limit int
	var asJSON bool
	command := &cobra.Command{
		Use:   "list",
		Short: "List complete runtime kernel releases",
		Args:  cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			releases, err := a.releases.List(command.Context(), repository, limit)
			if err != nil {
				return err
			}
			release.SortByPublished(releases)
			if asJSON {
				return a.writeJSON(releases)
			}
			writer := tabwriter.NewWriter(a.out, 0, 4, 2, ' ', 0)
			_, _ = fmt.Fprintln(writer, "TAG\tPUBLISHED\tASSETS")
			for _, item := range releases {
				_, _ = fmt.Fprintf(writer, "%s\t%s\t%d\n", item.TagName, item.PublishedAt.Format(time.RFC3339), len(item.Assets))
			}
			return writer.Flush()
		},
	}
	command.Flags().StringVar(&repository, "repository", release.DefaultRepository, "GitHub owner/repository containing kernel releases")
	command.Flags().IntVar(&limit, "limit", 20, "maximum releases to return")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

func (a *application) newKernelReleaseDownloadCommand() *cobra.Command {
	var repository string
	var outputDirectory string
	var includeHeaders bool
	var asJSON bool
	command := &cobra.Command{
		Use:   "download [ref]",
		Short: "Download and verify one ABI-bound kernel release",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			ref := "latest"
			if len(args) == 1 {
				ref = args[0]
			}
			bundle, err := a.releases.DownloadBundle(command.Context(), repository, ref, outputDirectory, includeHeaders)
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(bundle)
			}
			_, err = fmt.Fprintf(a.out, "downloaded %s\nABI: %s\npackages: %d\ndirectory: %s\n", bundle.Release, bundle.ABI, len(bundle.Packages), outputDirectory)
			return err
		},
	}
	command.Flags().StringVar(&repository, "repository", release.DefaultRepository, "GitHub owner/repository containing kernel releases")
	command.Flags().StringVar(&outputDirectory, "output-dir", "kernel-bundle", "directory for verified packages and manifest")
	command.Flags().BoolVar(&includeHeaders, "headers", false, "also download matching header packages")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

func (a *application) newKernelInspectCommand() *cobra.Command {
	var asJSON bool
	command := &cobra.Command{
		Use:   "inspect <directory>",
		Short: "Validate local kernel packages as one ABI-bound bundle",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			bundle, err := kernel.DiscoverLocalBundle(args[0])
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(bundle)
			}
			_, err = fmt.Fprintf(a.out, "kernel bundle valid\nrelease: %s\nABI: %s\nversion: %s\npackages: %d\n", bundle.Release, bundle.ABI, bundle.Version, len(bundle.Packages))
			return err
		},
	}
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

func (a *application) newKernelBuildCommand() *cobra.Command {
	request := kernelbuild.Request{}
	command := &cobra.Command{
		Use:   "build",
		Short: "Build the custom SP11 kernel in the maintained Docker workflow",
		Long:  "Build the custom SP11 kernel using the OE repository's maintained ARM64 Docker workflow. Build and output directories must be inside that repository.",
		Args:  cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			return kernelbuild.New(nil).Run(command.Context(), request)
		},
	}
	command.Flags().StringVar(&request.RepositoryRoot, "repository-root", "", "OE repository root (auto-detected from the current directory)")
	command.Flags().StringVar(&request.GitURL, "git-url", kernelbuild.DefaultGitURL, "kernel source repository")
	command.Flags().StringVar(&request.GitBranch, "git-branch", kernelbuild.DefaultGitBranch, "kernel source branch or tag")
	command.Flags().StringVar(&request.WorkDirectory, "work-dir", "build/linux-armer/kernel-build", "repository-relative kernel build directory")
	command.Flags().StringVar(&request.OutputDirectory, "output-dir", "build/linux-armer/kernel", "repository-relative package output directory")
	command.Flags().IntVar(&request.Jobs, "jobs", 0, "parallel build jobs (zero lets the helper choose)")
	command.Flags().BoolVar(&request.ResetSource, "reset-source", false, "discard and recreate the helper's kernel source tree")
	command.Flags().BoolVar(&request.SkipClean, "skip-clean", false, "skip the Debian package clean step")
	command.Flags().BoolVar(&request.DryRun, "dry-run", false, "print the delegated Docker build without running it")
	return command
}
