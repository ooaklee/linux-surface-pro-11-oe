package cli

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/doctor"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/hardwaredoctor"
)

// hardwareDoctorWorkflow is the delivery layer's narrow view of live hardware
// inspection, keeping command tests independent of the host's devices.
type hardwareDoctorWorkflow interface {
	// Inspect returns one typed, redacted live-hardware report.
	Inspect(context.Context, hardwaredoctor.Options) (hardwaredoctor.Report, error)
}

// hardwareDoctorFactory constructs an inspector over the selected procfs and
// sysfs root only when the hardware command runs.
type hardwareDoctorFactory func(string) (hardwareDoctorWorkflow, error)

// alternateRootProbeRunner makes process-based evidence unavailable rather
// than mixing an alternate filesystem snapshot with the current host.
type alternateRootProbeRunner struct{}

// Run rejects every external probe for an alternate diagnostic root.
func (alternateRootProbeRunner) Run(ctx context.Context, _ hardwaredoctor.Probe, _ int64) (hardwaredoctor.ProbeResult, error) {
	if err := ctx.Err(); err != nil {
		return hardwaredoctor.ProbeResult{}, err
	}
	return hardwaredoctor.ProbeResult{}, fmt.Errorf("external hardware probes are unavailable for an alternate root")
}

// newDoctorCommand checks host image-building prerequisites and provides the
// nested static userspace and live hardware diagnostic commands.
func (a *application) newDoctorCommand() *cobra.Command {
	var workspace string
	var asJSON bool
	command := &cobra.Command{
		Use:   "doctor",
		Short: "Check whether this host can build and validate images",
		Args:  cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			report := doctor.New(nil).Run(command.Context(), workspace)
			if asJSON {
				if err := a.writeJSON(report); err != nil {
					return err
				}
			} else {
				for _, check := range report.Checks {
					_, _ = fmt.Fprintf(a.out, "%-4s  %-20s %s\n", check.Status, check.Name, check.Details)
				}
			}
			if !report.Ready {
				return fmt.Errorf("required host checks failed")
			}
			return nil
		},
	}
	command.Flags().StringVar(&workspace, "workspace", ".", "directory that will hold temporary image data")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	command.AddCommand(
		a.newUserspaceStatusDeliveryCommand("userspace", "Report missing Surface Pro 11 userspace support"),
		a.newHardwareDoctorCommand(nil),
	)
	return command
}

// newHardwareDoctorCommand builds scriptable live hardware diagnostics with
// positional feature selection and deterministic human or JSON delivery.
func (a *application) newHardwareDoctorCommand(factory hardwareDoctorFactory) *cobra.Command {
	var root string
	var asJSON bool
	command := &cobra.Command{
		Use:       "hardware [wifi|bluetooth|audio|touchscreen ...]",
		Short:     "Report redacted live Surface Pro 11 hardware state",
		ValidArgs: []string{"wifi", "bluetooth", "audio", "touchscreen"},
		Long: "Report bounded, read-only live hardware evidence without changing devices, radio blocks, services, networking, or audio routing. " +
			"An alternate root supplies filesystem evidence only; process-based checks are reported unavailable rather than querying the current host.",
		Args: cobra.ArbitraryArgs,
		RunE: func(command *cobra.Command, args []string) error {
			features := make([]hardwaredoctor.Feature, 0, len(args))
			for _, value := range args {
				feature, err := hardwaredoctor.ParseFeature(value)
				if err != nil {
					return err
				}
				features = append(features, feature)
			}
			selectedFactory := factory
			if selectedFactory == nil {
				selectedFactory = newHardwareDoctorWorkflow
			}
			workflow, err := selectedFactory(root)
			if err != nil {
				return fmt.Errorf("construct hardware doctor: %w", err)
			}
			report, err := workflow.Inspect(command.Context(), hardwaredoctor.Options{Features: features})
			if err != nil {
				return fmt.Errorf("inspect live hardware: %w", err)
			}
			if asJSON {
				if err := a.writeJSON(report); err != nil {
					return err
				}
			} else if err := a.writeHardwareDoctorReport(report); err != nil {
				return err
			}
			if !report.Ready {
				return fmt.Errorf("required live hardware checks failed; physical hardware qualification remains unproven")
			}
			return nil
		},
	}
	command.Flags().StringVar(&root, "root", "/", "Linux runtime root containing procfs and sysfs evidence")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// newHardwareDoctorWorkflow constructs the default read-only live inspector.
func newHardwareDoctorWorkflow(root string) (hardwareDoctorWorkflow, error) {
	if strings.TrimSpace(root) == "" {
		root = string(filepath.Separator)
	}
	filesystem, err := hardwaredoctor.NewOSFileSystem(root)
	if err != nil {
		return nil, err
	}
	var runner hardwaredoctor.ProbeRunner
	if !isLiveHardwareRoot(root) {
		runner = alternateRootProbeRunner{}
	}
	return hardwaredoctor.New(filesystem, runner)
}

// isLiveHardwareRoot reports whether root resolves to the current system root.
func isLiveHardwareRoot(root string) bool {
	if strings.TrimSpace(root) == "" {
		root = string(filepath.Separator)
	}
	absolute, err := filepath.Abs(root)
	if err != nil {
		return false
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return false
	}
	systemRoot, err := filepath.EvalSymlinks(string(filepath.Separator))
	return err == nil && filepath.Clean(resolved) == filepath.Clean(systemRoot)
}

// writeHardwareDoctorReport renders only the domain's redacted scalar fields
// and keeps observable readiness distinct from physical qualification.
func (a *application) writeHardwareDoctorReport(report hardwaredoctor.Report) error {
	writer := tabwriter.NewWriter(a.out, 0, 4, 2, ' ', 0)
	if _, err := fmt.Fprintln(writer, "STATE\tEVIDENCE\tFEATURE\tREQUIRED\tCHECK\tDETAIL"); err != nil {
		return err
	}
	for _, check := range report.Checks {
		feature := string(check.Feature)
		if feature == "" {
			feature = "platform"
		}
		if _, err := fmt.Fprintf(writer, "%s\t%s\t%s\t%t\t%s\t%s\n",
			check.State, check.Evidence, feature, check.Required, check.ID, check.Detail); err != nil {
			return err
		}
		if check.Remediation != "" {
			if _, err := fmt.Fprintf(writer, "\t\t\t\tremediation\t%s\n", check.Remediation); err != nil {
				return err
			}
		}
	}
	readiness := "ready"
	if !report.Ready {
		readiness = "not ready"
	}
	if _, err := fmt.Fprintf(writer, "\nobserved readiness:\t%s\nhardware qualification:\tnot proven by this read-only command\n", readiness); err != nil {
		return err
	}
	return writer.Flush()
}
