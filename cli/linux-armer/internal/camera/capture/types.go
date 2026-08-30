// Package capture discovers, configures, and validates the exact Surface Pro
// 11 IMX681 raw-camera route without reading camera MMIO or installing files.
package capture

import (
	"context"
	"io"
	"time"
)

const (
	// Width is the validated standalone IMX681 capture width in pixels.
	Width = 3840
	// Height is the validated standalone IMX681 capture height in pixels.
	Height = 2640
	// BytesPerLine is the packed RAW10 stride for one validated frame.
	BytesPerLine = 4800
	// BytesPerFrame is the exact payload size of one validated frame.
	BytesPerFrame = BytesPerLine * Height
	// MinimumFrames is the smallest capture accepted by temporal checks.
	MinimumFrames = 10
	// MaximumFrames bounds private output size and capture duration.
	MaximumFrames = 100
)

const (
	// sensorWidth fixes the sensor and complete CAMSS route to the proven mode.
	sensorWidth = Width
	// phyEntity names the one validated camera serial-interface PHY.
	phyEntity = "msm_csiphy2"
	// csidEntity names the one validated camera serial-interface decoder.
	csidEntity = "msm_csid0"
	// vfeEntity names the one validated VFE raw data interface.
	vfeEntity = "msm_vfe0_rdi0"
	// minimumCameraGeneration rejects kernels older than the integrated camera path.
	minimumCameraGeneration = 14
	// metadataTimeout bounds every non-streaming host command.
	metadataTimeout = 5 * time.Second
	// maximumMetadataBytes bounds each captured topology or format report.
	maximumMetadataBytes int64 = 2 << 20
)

// BayerOrder identifies the colour-filter order negotiated by the sensor.
type BayerOrder string

const (
	// BayerBGGR selects blue, green, green, red ordering.
	BayerBGGR BayerOrder = "BGGR"
	// BayerGBRG selects green, blue, red, green ordering.
	BayerGBRG BayerOrder = "GBRG"
	// BayerGRBG selects green, red, blue, green ordering.
	BayerGRBG BayerOrder = "GRBG"
	// BayerRGGB selects red, green, green, blue ordering.
	BayerRGGB BayerOrder = "RGGB"
)

// Options selects one bounded raw-camera validation run.
type Options struct {
	// Frames is the number of complete frames to capture; zero selects ten.
	Frames int
	// OutputPath is a new private raw file; empty creates a private temporary directory.
	OutputPath string
	// ExpectedRelease, when set, must equal the running kernel release exactly.
	ExpectedRelease string
	// DryRun discovers and validates the exact route without changing its graph.
	DryRun bool
}

// Pipeline records the non-identifying media route selected for capture.
type Pipeline struct {
	// MediaDevice is the unique media-controller node containing the route.
	MediaDevice string `json:"media_device"`
	// VideoDevice is the unique VFE capture node reached by the route.
	VideoDevice string `json:"video_device"`
	// SensorEntity is the discovered IMX681 entity name.
	SensorEntity string `json:"sensor_entity"`
	// SensorSourcePad is the source pad connected to the compiled PHY.
	SensorSourcePad int `json:"sensor_source_pad"`
	// SensorControlDevice is the optional sensor subdevice for manual controls.
	SensorControlDevice string `json:"sensor_control_device,omitempty"`
	// VideoEntity is the discovered entity owning VideoDevice.
	VideoEntity string `json:"video_entity"`
	// MediaBusFormat is the negotiated ten-bit Bayer media-bus code.
	MediaBusFormat string `json:"media_bus_format"`
	// PixelFormat is the matching packed-RAW10 V4L2 fourcc.
	PixelFormat string `json:"pixel_format"`
	// BayerOrder is derived only from the negotiated media-bus code.
	BayerOrder BayerOrder `json:"bayer_order"`
}

// Evidence identifies the private files retained for review after capture.
type Evidence struct {
	// Raw is the exact concatenated packed-RAW10 capture.
	Raw string `json:"raw"`
	// MediaBefore is the bounded graph observed before configuration.
	MediaBefore string `json:"media_before"`
	// MediaAfter is the bounded graph observed after configuration.
	MediaAfter string `json:"media_after"`
	// V4L2Log is the bounded streaming diagnostic log.
	V4L2Log string `json:"v4l2_log"`
	// KernelLog is the bounded post-capture camera-related kernel log.
	KernelLog string `json:"kernel_log"`
	// Statistics is the private JSON content-analysis report.
	Statistics string `json:"statistics"`
}

// FrameStatistics describes one sampled frame without retaining pixel values.
type FrameStatistics struct {
	// Index is the zero-based frame number.
	Index int `json:"index"`
	// SHA256 identifies the complete private frame for comparison.
	SHA256 string `json:"sha256"`
	// SampleMinimum is the smallest sampled ten-bit code.
	SampleMinimum uint16 `json:"sample_minimum"`
	// SampleMaximum is the largest sampled ten-bit code.
	SampleMaximum uint16 `json:"sample_maximum"`
}

// Statistics records bounded sampled-content evidence for a complete capture.
type Statistics struct {
	// FrameSize is the exact validated byte count per frame.
	FrameSize int `json:"frame_size"`
	// FrameCount is the number of complete frames analysed.
	FrameCount int `json:"frame_count"`
	// SampleGroupStep is the deterministic RAW10 group sampling interval.
	SampleGroupStep int `json:"sample_group_step"`
	// SampleCount is the total decoded sample count.
	SampleCount int64 `json:"sample_count"`
	// SampleMinimum is the smallest sampled ten-bit code across every frame.
	SampleMinimum uint16 `json:"sample_minimum"`
	// SampleMaximum is the largest sampled ten-bit code across every frame.
	SampleMaximum uint16 `json:"sample_maximum"`
	// DistinctCodes is the number of sampled ten-bit codes observed.
	DistinctCodes int `json:"distinct_codes"`
	// Mean is the arithmetic mean of all sampled codes.
	Mean float64 `json:"mean"`
	// StandardDeviation is the population standard deviation of sampled codes.
	StandardDeviation float64 `json:"standard_deviation"`
	// EntropyBits is the Shannon entropy of the sampled code histogram.
	EntropyBits float64 `json:"entropy_bits"`
	// MinimumTemporalChange is the lowest adjacent-frame sampled change ratio.
	MinimumTemporalChange float64 `json:"minimum_temporal_change"`
	// Frames records per-frame identity and range evidence.
	Frames []FrameStatistics `json:"frames"`
}

// Result reports one complete transport and sampled-content validation.
type Result struct {
	// DryRun reports that no graph configuration or streaming was attempted.
	DryRun bool `json:"dry_run"`
	// RunningRelease is the exact kernel ABI used for the capture.
	RunningRelease string `json:"running_release"`
	// Frames is the number of complete frames captured.
	Frames int `json:"frames"`
	// Bytes is the exact aggregate raw payload size.
	Bytes int64 `json:"bytes"`
	// Pipeline is the unique route configured and revalidated.
	Pipeline Pipeline `json:"pipeline"`
	// Evidence names the private output files retained for inspection.
	Evidence Evidence `json:"evidence"`
	// SampleRange is the observed maximum less minimum sampled code.
	SampleRange int `json:"sample_range"`
	// DistinctCodes is the number of sampled ten-bit codes observed.
	DistinctCodes int `json:"distinct_codes"`
	// StandardDeviation is the sampled-code population standard deviation.
	StandardDeviation float64 `json:"standard_deviation"`
	// EntropyBits is the sampled-code Shannon entropy.
	EntropyBits float64 `json:"entropy_bits"`
	// MinimumTemporalChange is the lowest adjacent-frame sampled change ratio.
	MinimumTemporalChange float64 `json:"minimum_temporal_change"`
	// HardwareQualified remains false until the manual LED and lifecycle gates pass.
	HardwareQualified bool `json:"hardware_qualified"`
}

// Command is one compiled, argument-separated external camera operation.
type Command struct {
	// Name is the sole executable name selected by the native workflow.
	Name string
	// Args are passed directly and are never interpreted by a shell.
	Args []string
}

// Runner executes the small compiled media-controller command vocabulary.
type Runner interface {
	// Capture runs one command and returns bounded standard output.
	Capture(context.Context, Command, int64) ([]byte, error)
	// Run executes one command with explicit bounded log destinations.
	Run(context.Context, Command, io.Writer, io.Writer) error
}

// Manager orchestrates topology discovery, exact configuration, capture, and
// content analysis through an injected process boundary.
type Manager struct {
	// Runner executes only commands assembled by this package.
	Runner Runner
	// mediaDevices lists candidate controller nodes in deterministic order.
	mediaDevices func() ([]string, error)
	// runningRelease returns the current kernel release.
	runningRelease func(context.Context) (string, error)
	// modulePresent reports whether one required current-kernel module is loaded.
	modulePresent func(string) bool
	// validateDevice checks that a selected path is an accessible character device.
	validateDevice func(string) error
	// now supplies the kernel-log start boundary.
	now func() time.Time
	// hostOS records the runtime platform and is injectable for deterministic tests.
	hostOS string
}
