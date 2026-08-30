package releaseprep

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

const (
	// zstdCompressionLevel is fixed so one encoder version and input have one output.
	zstdCompressionLevel = 6
	// zstdThreadCount disables scheduling-dependent multi-threaded frame choices.
	zstdThreadCount = 1
	// maximumToolVersionBytes bounds external version text stored in provenance.
	maximumToolVersionBytes = 512
)

// ZstdCompressor invokes the zstd executable directly without a command shell.
type ZstdCompressor struct {
	// Runner is the external-process boundary used for compression and decoding.
	Runner platform.Runner
}

// NewZstdCompressor constructs the production deterministic zstd adapter.
func NewZstdCompressor(runner platform.Runner) *ZstdCompressor {
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	return &ZstdCompressor{Runner: runner}
}

// Compress writes a single-threaded, checksummed zstd frame to output.
func (compressor *ZstdCompressor) Compress(ctx context.Context, input io.Reader, output io.Writer) (CompressionTool, error) {
	if compressor == nil || compressor.Runner == nil {
		return CompressionTool{}, errors.New("zstd compressor is unavailable")
	}
	if input == nil || output == nil {
		return CompressionTool{}, errors.New("zstd compression requires input and output streams")
	}
	version, err := compressor.version(ctx)
	if err != nil {
		return CompressionTool{}, err
	}
	command := platform.Command{
		Name: "zstd",
		Args: []string{
			"--compress", "--stdout", "--no-progress", "--check",
			fmt.Sprintf("-%d", zstdCompressionLevel), fmt.Sprintf("--threads=%d", zstdThreadCount),
		},
		Env: []string{"LC_ALL=C", "TZ=UTC"}, Stdin: input, Stdout: output,
	}
	if err := compressor.Runner.Run(ctx, command); err != nil {
		return CompressionTool{}, fmt.Errorf("compress image with zstd: %w", err)
	}
	return CompressionTool{
		Format: "zstd", Implementation: "zstd-cli", Version: version,
		Level: zstdCompressionLevel, Threads: zstdThreadCount, ContentChecksum: true,
	}, nil
}

// Decompress writes one zstd frame to output for streaming identity checks.
func (compressor *ZstdCompressor) Decompress(ctx context.Context, input io.Reader, output io.Writer) error {
	if compressor == nil || compressor.Runner == nil {
		return errors.New("zstd compressor is unavailable")
	}
	if input == nil || output == nil {
		return errors.New("zstd decompression requires input and output streams")
	}
	command := platform.Command{
		Name: "zstd", Args: []string{"--decompress", "--stdout", "--no-progress"},
		Env: []string{"LC_ALL=C", "TZ=UTC"}, Stdin: input, Stdout: output,
	}
	if err := compressor.Runner.Run(ctx, command); err != nil {
		return fmt.Errorf("decompress image with zstd: %w", err)
	}
	return nil
}

// version returns one bounded printable line suitable for public provenance.
func (compressor *ZstdCompressor) version(ctx context.Context) (string, error) {
	output, err := compressor.Runner.Capture(ctx, platform.Command{
		Name: "zstd", Args: []string{"--version"}, Env: []string{"LC_ALL=C", "TZ=UTC"},
	})
	if err != nil {
		return "", fmt.Errorf("inspect zstd version: %w", err)
	}
	if len(output) == 0 || len(output) > maximumToolVersionBytes || !utf8.Valid(output) || bytes.IndexByte(output, 0) >= 0 {
		return "", errors.New("zstd returned invalid or overlong version text")
	}
	version := strings.TrimSpace(string(output))
	if version == "" || strings.ContainsAny(version, "\r\n") {
		return "", errors.New("zstd returned an empty or multi-line version")
	}
	for _, character := range version {
		if character < 0x20 || character == 0x7f {
			return "", errors.New("zstd returned control bytes in its version")
		}
	}
	return version, nil
}
