package releaseprep

import (
	"bytes"
	"context"
	"os/exec"
	"testing"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// TestZstdCompressorRoundTripAndDeterminism exercises the real shell-free adapter.
func TestZstdCompressorRoundTripAndDeterminism(t *testing.T) {
	if _, err := exec.LookPath("zstd"); err != nil {
		t.Skip("zstd is not installed")
	}
	compressor := NewZstdCompressor(platform.ExecRunner{})
	input := bytes.Repeat([]byte("linux-armer deterministic image release\n"), 257)
	var first, second bytes.Buffer
	firstTool, err := compressor.Compress(context.Background(), bytes.NewReader(input), &first)
	if err != nil {
		t.Fatal(err)
	}
	secondTool, err := compressor.Compress(context.Background(), bytes.NewReader(input), &second)
	if err != nil {
		t.Fatal(err)
	}
	if firstTool != secondTool || !bytes.Equal(first.Bytes(), second.Bytes()) {
		t.Fatal("the same zstd implementation and source produced different bytes")
	}
	var reconstructed bytes.Buffer
	if err := compressor.Decompress(context.Background(), bytes.NewReader(first.Bytes()), &reconstructed); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(reconstructed.Bytes(), input) {
		t.Fatal("zstd round trip changed the input bytes")
	}
}
