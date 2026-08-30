package rawpreview

import (
	"bytes"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// tinyLayout keeps parser and PNG tests fast while exercising real RAW10 packing.
var tinyLayout = frameLayout{width: 4, height: 2, stride: 5, frameSize: 10}

// TestParseBayerOrderAcceptsOnlyCompiledValues rejects catalogue-like free-form input.
func TestParseBayerOrderAcceptsOnlyCompiledValues(t *testing.T) {
	for _, value := range []string{"auto", "BGGR", "GBRG", "GRBG", "RGGB"} {
		if _, err := ParseBayerOrder(value); err != nil {
			t.Fatalf("ParseBayerOrder(%q): %v", value, err)
		}
	}
	if _, err := ParseBayerOrder("rggb"); err == nil {
		t.Fatal("expected lower-case order to be rejected")
	}
	if _, err := ParseBayerOrder(""); err == nil {
		t.Fatal("expected an empty order to be rejected")
	}
}

// TestDiscoverBayerOrderRequiresOneUnambiguousRegularSidecar verifies strict evidence parsing.
func TestDiscoverBayerOrderRequiresOneUnambiguousRegularSidecar(t *testing.T) {
	base := filepath.Join(t.TempDir(), "capture.raw")
	if err := os.WriteFile(base+topologySuffixes[0], []byte("fmt:SRGGB10_1X10/3840x2640\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	order, err := discoverBayerOrder(base)
	if err != nil {
		t.Fatal(err)
	}
	if order != BayerRGGB {
		t.Fatalf("order = %q", order)
	}
	if err := os.WriteFile(base+topologySuffixes[0], []byte("SBGGR10_1X10 SGBRG10_1X10"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := discoverBayerOrder(base); err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Fatalf("expected ambiguity error, got %v", err)
	}
}

// TestDiscoverBayerOrderUsesTheBoundedFallbackAndRejectsSymlinks checks hostile sidecars.
func TestDiscoverBayerOrderUsesTheBoundedFallbackAndRejectsSymlinks(t *testing.T) {
	directory := t.TempDir()
	base := filepath.Join(directory, "capture.raw")
	if _, err := discoverBayerOrder(base); err == nil {
		t.Fatal("expected missing sidecars to be rejected")
	}
	if err := os.WriteFile(base+topologySuffixes[0], []byte("no supported format here"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(base+topologySuffixes[1], []byte("SGBRG10_1X10"), 0o600); err != nil {
		t.Fatal(err)
	}
	order, err := discoverBayerOrder(base)
	if err != nil {
		t.Fatal(err)
	}
	if order != BayerGBRG {
		t.Fatalf("fallback order = %q", order)
	}
	if runtime.GOOS != "windows" {
		if err := os.Remove(base + topologySuffixes[0]); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(base+topologySuffixes[1], base+topologySuffixes[0]); err != nil {
			t.Fatal(err)
		}
		if _, err := discoverBayerOrder(base); err == nil || !strings.Contains(err.Error(), "non-symlink") {
			t.Fatalf("expected sidecar symlink rejection, got %v", err)
		}
	}
}

// TestReadOptionalRegularFileRejectsAnOversizedSidecar exercises its read limit.
func TestReadOptionalRegularFileRejectsAnOversizedSidecar(t *testing.T) {
	path := filepath.Join(t.TempDir(), "capture.raw.media-after.txt")
	if err := os.WriteFile(path, bytes.Repeat([]byte{'x'}, 33), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := readOptionalRegularFile(path, 32); err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("expected oversized sidecar rejection, got %v", err)
	}
}

// TestReadFrameRejectsSymlinksAndSelectsOneFrame checks private input boundaries.
func TestReadFrameRejectsSymlinksAndSelectsOneFrame(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "capture.raw")
	first := packRow([4]uint16{1, 2, 3, 4})
	second := packRow([4]uint16{100, 200, 300, 400})
	contents := append(append(append([]byte{}, first...), first...), append(second, second...)...)
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	frame, err := readFrame(path, 1, tinyLayout)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(frame, append(second, second...)) {
		t.Fatalf("unexpected second frame: %v", frame)
	}
	if runtime.GOOS != "windows" {
		link := filepath.Join(directory, "capture-link.raw")
		if err := os.Symlink(path, link); err != nil {
			t.Fatal(err)
		}
		if _, err := readFrame(link, 0, tinyLayout); err == nil {
			t.Fatal("expected symlinked input to be rejected")
		}
	}
}

// TestRenderCreatesAValidPrivatePNGAndNeverOverwrites validates the complete small-frame flow.
func TestRenderCreatesAValidPrivatePNGAndNeverOverwrites(t *testing.T) {
	directory := t.TempDir()
	input := filepath.Join(directory, "capture.raw")
	output := filepath.Join(directory, "preview.png")
	row0 := packRow([4]uint16{10, 20, 30, 40})
	row1 := packRow([4]uint16{50, 60, 70, 80})
	if err := os.WriteFile(input, append(row0, row1...), 0o600); err != nil {
		t.Fatal(err)
	}
	result, err := render(Options{
		InputPath: input, OutputPath: output, BayerOrder: BayerRGGB, Linear: true,
	}, tinyLayout)
	if err != nil {
		t.Fatal(err)
	}
	if result.Width != 2 || result.Height != 1 || result.BayerOrder != BayerRGGB {
		t.Fatalf("unexpected result: %+v", result)
	}
	file, err := os.Open(output)
	if err != nil {
		t.Fatal(err)
	}
	image, err := png.Decode(file)
	closeErr := file.Close()
	if err != nil || closeErr != nil {
		t.Fatalf("decode PNG: %v; close: %v", err, closeErr)
	}
	if image.Bounds().Dx() != 2 || image.Bounds().Dy() != 1 {
		t.Fatalf("PNG bounds = %v", image.Bounds())
	}
	firstPixel := color.NRGBAModel.Convert(image.At(0, 0)).(color.NRGBA)
	if firstPixel != (color.NRGBA{R: 2, G: 9, B: 15, A: 255}) {
		t.Fatalf("first preview pixel = %+v", firstPixel)
	}
	info, err := os.Stat(output)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0o077 != 0 {
		t.Fatalf("output mode is not private: %o", info.Mode().Perm())
	}
	if _, err := render(Options{
		InputPath: input, OutputPath: output, BayerOrder: BayerRGGB, Linear: true,
	}, tinyLayout); err == nil {
		t.Fatal("expected an existing output to be rejected")
	}
	secondOutput := filepath.Join(directory, "preview-copy.png")
	if _, err := render(Options{
		InputPath: input, OutputPath: secondOutput, BayerOrder: BayerRGGB, Linear: true,
	}, tinyLayout); err != nil {
		t.Fatal(err)
	}
	firstPNG, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	secondPNG, err := os.ReadFile(secondOutput)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(firstPNG, secondPNG) {
		t.Fatal("identical captures did not produce identical PNG bytes")
	}
}

// TestReadFrameRejectsMalformedLengthsAndOutOfRangeFrames checks bounded indexing.
func TestReadFrameRejectsMalformedLengthsAndOutOfRangeFrames(t *testing.T) {
	path := filepath.Join(t.TempDir(), "capture.raw")
	if err := os.WriteFile(path, []byte{1, 2, 3}, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readFrame(path, 0, tinyLayout); err == nil || !strings.Contains(err.Error(), "positive multiple") {
		t.Fatalf("expected malformed-length rejection, got %v", err)
	}
	if err := os.WriteFile(path, make([]byte, tinyLayout.frameSize), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readFrame(path, 1, tinyLayout); err == nil || !strings.Contains(err.Error(), "outside the available range") {
		t.Fatalf("expected out-of-range rejection, got %v", err)
	}
}

// TestPercentileBoundsMatchesNearestRankPolicy protects the preview-stretch contract.
func TestPercentileBoundsMatchesNearestRankPolicy(t *testing.T) {
	var histogram [1024]uint64
	for code := 0; code < 100; code++ {
		histogram[code] = 1
	}
	low, high := percentileBounds(histogram)
	if low != 0 || high != 98 {
		t.Fatalf("bounds = %d..%d", low, high)
	}
}

// TestPercentileBoundsUsesAValidFullRangeForAConstantFrame avoids an invalid
// 1024 code and preserves the captured brightness in degenerate previews.
func TestPercentileBoundsUsesAValidFullRangeForAConstantFrame(t *testing.T) {
	var histogram [1024]uint64
	histogram[1023] = 10
	low, high := percentileBounds(histogram)
	if low != 0 || high != 1023 {
		t.Fatalf("constant-frame bounds = %d..%d", low, high)
	}
	lookup, _, _ := makeLookup(histogram, false)
	if lookup[1023] != 255 {
		t.Fatalf("constant maximum code maps to %d", lookup[1023])
	}
}

// TestPreviewLookupMatchesPythonReferenceVectors pins the semantic port rather
// than comparing compressor-specific PNG bytes.
func TestPreviewLookupMatchesPythonReferenceVectors(t *testing.T) {
	var histogram [1024]uint64
	histogram[100] = 1
	histogram[500] = 97
	histogram[900] = 2
	lookup, low, high := makeLookup(histogram, false)
	if low != 100 || high != 900 {
		t.Fatalf("bounds = %d..%d", low, high)
	}
	expected := map[int]byte{0: 0, 100: 0, 101: 13, 250: 120, 500: 187, 899: 255, 900: 255, 1023: 255}
	for code, value := range expected {
		if lookup[code] != value {
			t.Fatalf("lookup[%d] = %d, expected Python reference value %d", code, lookup[code], value)
		}
	}
}

// packRow produces one four-pixel V4L2 packed-RAW10 test row.
func packRow(values [4]uint16) []byte {
	return []byte{
		byte(values[0] >> 2), byte(values[1] >> 2),
		byte(values[2] >> 2), byte(values[3] >> 2),
		byte(values[0]&3) | byte(values[1]&3)<<2 | byte(values[2]&3)<<4 | byte(values[3]&3)<<6,
	}
}
