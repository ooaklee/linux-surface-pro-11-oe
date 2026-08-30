package capture

import (
	"bytes"
	"context"
	"strings"
	"testing"
)

// TestAnalyseFramesAcceptsChangingNonFlatRAW10 verifies the complete sampled
// range, entropy, frame-identity, and temporal-change path on a small fixture.
func TestAnalyseFramesAcceptsChangingNonFlatRAW10(t *testing.T) {
	t.Parallel()
	const frameSize = 5 * 64
	var capture bytes.Buffer
	for frame := 0; frame < MinimumFrames; frame++ {
		for group := 0; group < frameSize/5; group++ {
			capture.Write([]byte{
				byte(group + frame), byte(group*3 + frame),
				byte(group*5 + frame), byte(group*7 + frame),
				byte(group*11 + frame),
			})
		}
	}
	statistics, err := analyseFrames(context.Background(), bytes.NewReader(capture.Bytes()), MinimumFrames, frameSize)
	if err != nil {
		t.Fatal(err)
	}
	if statistics.FrameCount != MinimumFrames || statistics.FrameSize != frameSize || len(statistics.Frames) != MinimumFrames {
		t.Fatalf("statistics shape = %#v", statistics)
	}
	if statistics.DistinctCodes < 8 || statistics.StandardDeviation < 1 || statistics.EntropyBits < 1 || statistics.MinimumTemporalChange <= 0 {
		t.Fatalf("content gates were not represented: %#v", statistics)
	}
}

// TestAnalyseFramesRejectsFlatOrTrailingContent verifies exact boundaries and
// non-flat sampled content are independent mandatory gates.
func TestAnalyseFramesRejectsFlatOrTrailingContent(t *testing.T) {
	t.Parallel()
	const frameSize = 5 * 8
	flat := bytes.Repeat([]byte{0}, frameSize*MinimumFrames)
	if _, err := analyseFrames(context.Background(), bytes.NewReader(flat), MinimumFrames, frameSize); err == nil ||
		!strings.Contains(err.Error(), "byte-identical") {
		t.Fatalf("flat capture error = %v", err)
	}
	changing := make([]byte, frameSize*MinimumFrames+1)
	for index := range changing[:len(changing)-1] {
		changing[index] = byte(index)
	}
	if _, err := analyseFrames(context.Background(), bytes.NewReader(changing), MinimumFrames, frameSize); err == nil ||
		!strings.Contains(err.Error(), "after the expected final frame") {
		t.Fatalf("trailing capture error = %v", err)
	}
}

// TestDecodeRAW10GroupUsesLeastPixelFirstTails verifies the packed V4L2 bit
// layout shared with the native preview renderer.
func TestDecodeRAW10GroupUsesLeastPixelFirstTails(t *testing.T) {
	t.Parallel()
	got := decodeRAW10Group([]byte{1, 2, 3, 4, 0b11100100})
	want := [4]uint16{4, 9, 14, 19}
	if got != want {
		t.Fatalf("decodeRAW10Group() = %v, want %v", got, want)
	}
}
