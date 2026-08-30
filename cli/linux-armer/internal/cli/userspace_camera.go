package cli

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"

	cameracapture "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/capture"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/rawpreview"
)

// cameraPreviewRenderer is the delivery layer's narrow view of native RAW rendering.
type cameraPreviewRenderer func(rawpreview.Options) (rawpreview.Result, error)

// cameraCaptureWorkflow is the delivery layer's narrow view of native live
// IMX681 route discovery and raw transport validation.
type cameraCaptureWorkflow interface {
	// Run discovers or exercises the exact compiled camera route.
	Run(context.Context, cameracapture.Options) (cameracapture.Result, error)
}

// newUserspaceCameraCommand collects native camera inspection tools.
func (a *application) newUserspaceCameraCommand(renderer cameraPreviewRenderer) *cobra.Command {
	command := &cobra.Command{
		Use:   "camera",
		Short: "Inspect camera captures and prepare local package releases",
		Args:  cobra.NoArgs,
	}
	command.AddCommand(
		a.newUserspaceCameraCaptureCommand(nil),
		a.newUserspaceCameraRenderCommand(renderer),
		a.newUserspaceCameraReleaseCommand(nil),
	)
	return command
}

// newUserspaceCameraCaptureCommand builds the bounded live raw-camera
// discovery, capture, and sampled-content validation command.
func (a *application) newUserspaceCameraCaptureCommand(workflow cameraCaptureWorkflow) *cobra.Command {
	options := cameracapture.Options{}
	var asJSON bool
	command := &cobra.Command{
		Use:   "capture",
		Short: "Capture and validate private IMX681 RAW10 frames",
		Long: "Discover and optionally configure the exact IMX681 to CSIPHY2 to CSID0 to VFE0-RDI0 route, then capture complete packed-RAW10 frames and apply transport, content, temporal, and emitted-kernel-error gates. " +
			"This transient diagnostic never installs files, resets unrelated graph links, reads camera MMIO, or claims that the manual privacy-LED and lifecycle gates passed.",
		Args: cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			selectedWorkflow := workflow
			if selectedWorkflow == nil {
				selectedWorkflow = cameracapture.New(nil)
			}
			result, err := selectedWorkflow.Run(command.Context(), options)
			if err != nil {
				return fmt.Errorf("validate live IMX681 capture: %w", err)
			}
			if asJSON {
				return a.writeJSON(result)
			}
			return a.writeCameraCaptureResult(result)
		},
	}
	command.Flags().IntVar(&options.Frames, "frames", cameracapture.MinimumFrames,
		fmt.Sprintf("complete frame count (%d..%d)", cameracapture.MinimumFrames, cameracapture.MaximumFrames))
	command.Flags().StringVar(&options.OutputPath, "output", "", "new private RAW10 output path (default: a protected temporary directory)")
	command.Flags().StringVar(&options.ExpectedRelease, "expected-release", "", "optional exact running Surface kernel ABI")
	command.Flags().BoolVar(&options.DryRun, "dry-run", false, "discover and validate the route without configuring or streaming it")
	command.Flags().BoolVar(&asJSON, "json", false, "write one machine-readable result")
	return command
}

// writeCameraCaptureResult distinguishes a safe discovery plan from a passed
// byte/content gate and always leaves physical qualification explicit.
func (a *application) writeCameraCaptureResult(result cameracapture.Result) error {
	if result.DryRun {
		_, err := fmt.Fprintf(a.out,
			"camera route ready for transient validation\nkernel: %s\nroute: %s -> %s -> %s -> %s -> %s\nformat: %s %s RAW10, %d frames, %d bytes\nno graph or file was changed\n",
			result.RunningRelease, result.Pipeline.SensorEntity, "msm_csiphy2", "msm_csid0",
			"msm_vfe0_rdi0", result.Pipeline.VideoDevice, result.Pipeline.BayerOrder,
			result.Pipeline.PixelFormat, result.Frames, result.Bytes)
		return err
	}
	if _, err := fmt.Fprintf(a.out,
		"camera transport and sampled-content gates passed\nkernel: %s\nframes: %d complete (%d bytes)\nformat: %s %s RAW10\nsample range: %d codes; distinct: %d; standard deviation: %.3f; entropy: %.3f bits\nminimum adjacent temporal change: %.6f%%\nraw: %s\nstatistics: %s\nmedia topology: %s\n                %s\nV4L2 log: %s\nkernel log: %s\n",
		result.RunningRelease, result.Frames, result.Bytes, result.Pipeline.BayerOrder,
		result.Pipeline.PixelFormat, result.SampleRange, result.DistinctCodes,
		result.StandardDeviation, result.EntropyBits, result.MinimumTemporalChange*100,
		result.Evidence.Raw, result.Evidence.Statistics, result.Evidence.MediaBefore,
		result.Evidence.MediaAfter, result.Evidence.V4L2Log, result.Evidence.KernelLog); err != nil {
		return err
	}
	_, err := fmt.Fprintln(a.out,
		"Hardware qualification is still not proven: inspect a rendered frame, confirm the privacy LED lifetime manually, and repeat start/stop plus suspend/resume without reading camera MMIO.")
	return err
}

// newUserspaceCameraRenderCommand builds a deterministic packed-RAW10 preview command.
func (a *application) newUserspaceCameraRenderCommand(renderer cameraPreviewRenderer) *cobra.Command {
	var frameIndex int
	var orderValue string
	var linear bool
	var asJSON bool
	command := &cobra.Command{
		Use:   "render <capture.raw> <preview.png>",
		Short: "Render one private IMX681 RAW10 frame as a PNG",
		Long: "Render one exact 3840x2640 V4L2 packed-RAW10 frame as a half-resolution inspection PNG. " +
			"The output must not exist and is created with mode 0600 on Unix hosts. Automatic Bayer discovery reads only the validator's bounded topology sidecars.",
		Args: cobra.ExactArgs(2),
		RunE: func(_ *cobra.Command, args []string) error {
			if frameIndex < 0 {
				return fmt.Errorf("frame index must not be negative")
			}
			order, err := rawpreview.ParseBayerOrder(orderValue)
			if err != nil {
				return err
			}
			selectedRenderer := renderer
			if selectedRenderer == nil {
				selectedRenderer = rawpreview.Render
			}
			result, err := selectedRenderer(rawpreview.Options{
				InputPath: args[0], OutputPath: args[1], FrameIndex: frameIndex,
				BayerOrder: order, Linear: linear,
			})
			if err != nil {
				return fmt.Errorf("render private camera preview: %w", err)
			}
			if asJSON {
				return a.writeJSON(result)
			}
			if _, err := fmt.Fprintf(a.out,
				"rendered frame %d: %dx%d %s RAW10 -> %dx%d PNG (%s)\noutput: %s\n",
				result.FrameIndex, rawpreview.IMX681Width, rawpreview.IMX681Height,
				result.BayerOrder, result.Width, result.Height, result.Mapping, result.OutputPath); err != nil {
				return err
			}
			if !linear {
				_, err = fmt.Fprintln(a.out, "This inspection preview is auto-stretched; use --linear for exposure or gain comparisons.")
			}
			return err
		},
	}
	command.Flags().IntVar(&frameIndex, "frame", 0, "zero-based frame index within the capture")
	command.Flags().StringVar(&orderValue, "bayer-order", "auto", "Bayer order: auto, BGGR, GBRG, GRBG, or RGGB")
	command.Flags().BoolVar(&linear, "linear", false, "map ten-bit codes linearly for exposure or gain comparisons")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}
