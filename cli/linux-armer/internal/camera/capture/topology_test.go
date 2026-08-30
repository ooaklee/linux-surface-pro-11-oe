package capture

import (
	"fmt"
	"strings"
	"testing"
)

// TestDiscoverPipelineSelectsExactIMX681Route verifies graph discovery derives
// its Bayer and video formats from the negotiated sensor code.
func TestDiscoverPipelineSelectsExactIMX681Route(t *testing.T) {
	t.Parallel()
	topology, err := parseTopology(cameraTopologyFixture("SRGGB10_1X10"))
	if err != nil {
		t.Fatal(err)
	}
	pipeline, err := discoverPipeline("/dev/media3", topology)
	if err != nil {
		t.Fatal(err)
	}
	if pipeline.SensorEntity != "imx681 1-0010" || pipeline.SensorSourcePad != 0 ||
		pipeline.SensorControlDevice != "/dev/v4l-subdev7" ||
		pipeline.VideoDevice != "/dev/video12" || pipeline.VideoEntity != "video-output0" {
		t.Fatalf("pipeline = %#v", pipeline)
	}
	if pipeline.MediaBusFormat != "SRGGB10_1X10" || pipeline.PixelFormat != "pRAA" || pipeline.BayerOrder != BayerRGGB {
		t.Fatalf("format mapping = %#v", pipeline)
	}
	if err := validateConfiguredTopology(topology, pipeline); err != nil {
		t.Fatalf("configured topology rejected: %v", err)
	}
}

// TestDiscoverPipelineRejectsUnsupportedOrAmbiguousSensors verifies the route
// cannot silently guess a Bayer order or choose between two sensors.
func TestDiscoverPipelineRejectsUnsupportedOrAmbiguousSensors(t *testing.T) {
	t.Parallel()
	unsupported, err := parseTopology(cameraTopologyFixture("Y10_1X10"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := discoverPipeline("/dev/media0", unsupported); err == nil || !strings.Contains(err.Error(), "unsupported") {
		t.Fatalf("unsupported Bayer error = %v", err)
	}
	ambiguousText := cameraTopologyFixture("SBGGR10_1X10") + `
- entity 20: imx681 auxiliary (1 pad, 1 link)
    device node name /dev/v4l-subdev20
    pad0: Source
        [fmt:SBGGR10_1X10/3840x2640]
        -> "msm_csiphy2":0 [ENABLED]
`
	ambiguous, err := parseTopology(ambiguousText)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := discoverPipeline("/dev/media0", ambiguous); err == nil || !strings.Contains(err.Error(), "found 2") {
		t.Fatalf("ambiguous sensor error = %v", err)
	}
}

// TestDiscoverPipelineRequiresTheCompleteDeclaredRoute verifies discovery
// cannot infer a connection merely because the expected entities exist.
func TestDiscoverPipelineRequiresTheCompleteDeclaredRoute(t *testing.T) {
	t.Parallel()
	broken := strings.Replace(
		cameraTopologyFixture("SBGGR10_1X10"),
		`-> "msm_csid0":0 [ENABLED]`,
		`-> "msm_csid1":0 [ENABLED]`, 1,
	)
	topology, err := parseTopology(broken)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := discoverPipeline("/dev/media0", topology); err == nil || !strings.Contains(err.Error(), "camera route source pad") {
		t.Fatalf("missing route-link error = %v", err)
	}
}

// TestValidateConfiguredTopologyRequiresEnabledLinks verifies format agreement
// alone cannot pass when a mutable route connection remains disabled.
func TestValidateConfiguredTopologyRequiresEnabledLinks(t *testing.T) {
	t.Parallel()
	text := strings.Replace(
		cameraTopologyFixture("SBGGR10_1X10"),
		`-> "msm_csid0":0 [ENABLED]`,
		`-> "msm_csid0":0 [0]`, 1,
	)
	topology, err := parseTopology(text)
	if err != nil {
		t.Fatal(err)
	}
	pipeline, err := discoverPipeline("/dev/media0", topology)
	if err != nil {
		t.Fatalf("declared disabled link should remain configurable: %v", err)
	}
	if err := validateConfiguredTopology(topology, pipeline); err == nil || !strings.Contains(err.Error(), "not enabled") {
		t.Fatalf("disabled configured-link error = %v", err)
	}
}

// TestFormatMappingCoversEveryNegotiatedBayerOrder verifies no supported code
// is accidentally mapped to another packed fourcc.
func TestFormatMappingCoversEveryNegotiatedBayerOrder(t *testing.T) {
	t.Parallel()
	tests := []struct {
		media string
		pixel string
		order BayerOrder
	}{
		{"SBGGR10_1X10", "pBAA", BayerBGGR},
		{"SGBRG10_1X10", "pGAA", BayerGBRG},
		{"SGRBG10_1X10", "pgAA", BayerGRBG},
		{"SRGGB10_1X10", "pRAA", BayerRGGB},
	}
	for _, test := range tests {
		t.Run(test.media, func(t *testing.T) {
			t.Parallel()
			pixel, order, err := formatMapping(test.media)
			if err != nil || pixel != test.pixel || order != test.order {
				t.Fatalf("formatMapping(%q) = %q, %q, %v", test.media, pixel, order, err)
			}
		})
	}
}

// cameraTopologyFixture returns one complete exact-format media-ctl graph.
func cameraTopologyFixture(mediaBusFormat string) string {
	return fmt.Sprintf(`Media controller API version 6.10.0

- entity 1: imx681 1-0010 (1 pad, 1 link)
    device node name /dev/v4l-subdev7
    pad0: Source
        [fmt:%s/3840x2640 field:none]
        -> "msm_csiphy2":0 [ENABLED,IMMUTABLE]

- entity 2: msm_csiphy2 (2 pads, 2 links)
    pad0: Sink
        [fmt:%s/3840x2640 field:none]
    pad1: Source
        [fmt:%s/3840x2640 field:none]
        -> "msm_csid0":0 [ENABLED]

- entity 3: msm_csid0 (2 pads, 2 links)
    pad0: Sink
        [fmt:%s/3840x2640 field:none]
    pad1: Source
        [fmt:%s/3840x2640 field:none]
        -> "msm_vfe0_rdi0":0 [ENABLED]

- entity 4: msm_vfe0_rdi0 (2 pads, 2 links)
    pad0: Sink
        [fmt:%s/3840x2640 field:none]
    pad1: Source
        [fmt:%s/3840x2640 field:none]
        -> "video-output0":0 [ENABLED]

- entity 5: video-output0 (1 pad, 1 link)
    device node name /dev/video12
    pad0: Sink
        <- "msm_vfe0_rdi0":1 [ENABLED]
`, mediaBusFormat, mediaBusFormat, mediaBusFormat, mediaBusFormat,
		mediaBusFormat, mediaBusFormat, mediaBusFormat)
}
