// Package rawpreview renders private Surface Pro 11 IMX681 packed-RAW10
// captures as repeatable inspection PNGs within one released CLI build.
package rawpreview

import "fmt"

// IMX681Width is the validated SP11 sensor output width in pixels.
const IMX681Width = 3840

// IMX681Height is the validated SP11 sensor output height in pixels.
const IMX681Height = 2640

// IMX681Stride is the packed-RAW10 row length in bytes.
const IMX681Stride = 4800

// IMX681FrameSize is the exact byte length of one validated capture frame.
const IMX681FrameSize = IMX681Stride * IMX681Height

// maximumTopologyBytes bounds each optional media-topology sidecar read.
const maximumTopologyBytes = 4 << 20

// BayerOrder identifies the colour-filter order within each two-by-two cell.
type BayerOrder string

// Supported Bayer orders include automatic sidecar discovery and the four
// packed-RAW10 orders emitted by the Linux media graph.
const (
	BayerAuto BayerOrder = "auto"
	BayerBGGR BayerOrder = "BGGR"
	BayerGBRG BayerOrder = "GBRG"
	BayerGRBG BayerOrder = "GRBG"
	BayerRGGB BayerOrder = "RGGB"
)

// Options selects one private capture frame and one new PNG output path.
type Options struct {
	// InputPath names a regular packed-RAW10 capture produced by the validator.
	InputPath string
	// OutputPath names a new PNG and must not already exist.
	OutputPath string
	// FrameIndex is the zero-based frame to render.
	FrameIndex int
	// BayerOrder is explicit or BayerAuto for strict sidecar discovery.
	BayerOrder BayerOrder
	// Linear preserves relative 10-bit brightness instead of preview stretching.
	Linear bool
}

// Result records the deterministic interpretation and output of one render.
type Result struct {
	// InputPath is the capture path supplied by the caller.
	InputPath string `json:"input_path"`
	// OutputPath is the exclusively created private PNG.
	OutputPath string `json:"output_path"`
	// FrameIndex is the rendered zero-based frame.
	FrameIndex int `json:"frame_index"`
	// BayerOrder is the explicit or discovered colour-filter order.
	BayerOrder BayerOrder `json:"bayer_order"`
	// Mapping describes the 10-bit to 8-bit preview mapping.
	Mapping string `json:"mapping"`
	// LowerCode is the inclusive lower preview bound.
	LowerCode int `json:"lower_code"`
	// UpperCode is the inclusive upper preview bound.
	UpperCode int `json:"upper_code"`
	// Width is the rendered PNG width.
	Width int `json:"width"`
	// Height is the rendered PNG height.
	Height int `json:"height"`
	// Bytes is the complete PNG length written to disk.
	Bytes int64 `json:"bytes"`
}

// frameLayout describes one packed-RAW10 frame without exposing alternate
// layouts through the production API.
type frameLayout struct {
	width     int
	height    int
	stride    int
	frameSize int64
}

// imx681Layout is the sole production capture layout accepted by Render.
var imx681Layout = frameLayout{
	width: IMX681Width, height: IMX681Height, stride: IMX681Stride,
	frameSize: IMX681FrameSize,
}

// busCodeToBayer maps the exact media-bus tokens accepted from topology files.
var busCodeToBayer = map[string]BayerOrder{
	"SBGGR10_1X10": BayerBGGR,
	"SGBRG10_1X10": BayerGBRG,
	"SGRBG10_1X10": BayerGRBG,
	"SRGGB10_1X10": BayerRGGB,
}

// bayerCells maps each Bayer order to row-major two-by-two colour cells.
var bayerCells = map[BayerOrder][4]byte{
	BayerBGGR: {'B', 'G', 'G', 'R'},
	BayerGBRG: {'G', 'B', 'R', 'G'},
	BayerGRBG: {'G', 'R', 'B', 'G'},
	BayerRGGB: {'R', 'G', 'G', 'B'},
}

// ParseBayerOrder converts terminal input into one supported Bayer order.
func ParseBayerOrder(value string) (BayerOrder, error) {
	order := BayerOrder(value)
	if order == BayerAuto {
		return order, nil
	}
	if _, ok := bayerCells[order]; !ok {
		return "", fmt.Errorf("unsupported Bayer order %q; use auto, BGGR, GBRG, GRBG, or RGGB", value)
	}
	return order, nil
}
