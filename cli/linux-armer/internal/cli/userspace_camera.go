package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/rawpreview"
)

// cameraPreviewRenderer is the delivery layer's narrow view of native RAW rendering.
type cameraPreviewRenderer func(rawpreview.Options) (rawpreview.Result, error)

// newUserspaceCameraCommand collects native camera inspection tools.
func (a *application) newUserspaceCameraCommand(renderer cameraPreviewRenderer) *cobra.Command {
	command := &cobra.Command{
		Use:   "camera",
		Short: "Inspect Surface Pro 11 camera captures",
		Args:  cobra.NoArgs,
	}
	command.AddCommand(a.newUserspaceCameraRenderCommand(renderer))
	return command
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
