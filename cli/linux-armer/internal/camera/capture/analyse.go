package capture

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"math"
)

// Analyse validates exact frame boundaries and sampled packed-RAW10 content
// without retaining decoded image data outside the private process.
func Analyse(ctx context.Context, path string, frameCount int) (Statistics, error) {
	if ctx == nil {
		return Statistics{}, fmt.Errorf("analyse camera capture: context is nil")
	}
	if frameCount < MinimumFrames || frameCount > MaximumFrames {
		return Statistics{}, fmt.Errorf("camera frame count must be from %d through %d", MinimumFrames, MaximumFrames)
	}
	file, err := openRegularReadNoFollow(path)
	if err != nil {
		return Statistics{}, fmt.Errorf("open private camera capture: %w", err)
	}
	defer func() { _ = file.Close() }()
	info, err := file.Stat()
	if err != nil {
		return Statistics{}, fmt.Errorf("inspect private camera capture: %w", err)
	}
	expectedSize := int64(frameCount) * int64(BytesPerFrame)
	if !info.Mode().IsRegular() || info.Size() != expectedSize {
		return Statistics{}, fmt.Errorf("camera capture is %d bytes; %d complete frames require exactly %d bytes", info.Size(), frameCount, expectedSize)
	}
	statistics, err := analyseFrames(ctx, file, frameCount, BytesPerFrame)
	if err != nil {
		return Statistics{}, err
	}
	if err := file.Close(); err != nil {
		return Statistics{}, fmt.Errorf("close private camera capture: %w", err)
	}
	return statistics, nil
}

// analyseFrames performs the deterministic RAW10 sampling over an exact-sized
// reader; frameSize is injectable only so small fixtures can exercise the full
// analysis without allocating production-sized captures.
func analyseFrames(ctx context.Context, reader io.Reader, frameCount, frameSize int) (Statistics, error) {
	if frameCount < MinimumFrames || frameCount > MaximumFrames {
		return Statistics{}, fmt.Errorf("camera frame count must be from %d through %d", MinimumFrames, MaximumFrames)
	}
	if frameSize < 5 || frameSize%5 != 0 {
		return Statistics{}, fmt.Errorf("camera frame size must be a positive multiple of five bytes")
	}
	groupsPerFrame := frameSize / 5
	sampleStep := max(1, groupsPerFrame/65536)
	statistics := Statistics{
		FrameSize: frameSize, FrameCount: frameCount,
		SampleGroupStep: sampleStep, SampleMinimum: 1023,
		Frames: make([]FrameStatistics, 0, frameCount),
	}
	histogram := make([]int64, 1024)
	frame := make([]byte, frameSize)
	var previousSamples []uint16
	var previousDigest [sha256.Size]byte
	var sampleSum, sampleSquareSum float64
	minimumTemporalChange := 1.0
	for frameIndex := 0; frameIndex < frameCount; frameIndex++ {
		if err := ctx.Err(); err != nil {
			return Statistics{}, err
		}
		if _, err := io.ReadFull(reader, frame); err != nil {
			return Statistics{}, fmt.Errorf("read camera frame %d: %w", frameIndex, err)
		}
		digest := sha256.Sum256(frame)
		if frameIndex > 0 && digest == previousDigest {
			return Statistics{}, fmt.Errorf("camera frames %d and %d are byte-identical", frameIndex-1, frameIndex)
		}
		samples := make([]uint16, 0, ((groupsPerFrame+sampleStep-1)/sampleStep)*4)
		frameMinimum, frameMaximum := uint16(1023), uint16(0)
		for group := 0; group < groupsPerFrame; group += sampleStep {
			offset := group * 5
			values := decodeRAW10Group(frame[offset : offset+5])
			for _, value := range values {
				samples = append(samples, value)
				frameMinimum = min(frameMinimum, value)
				frameMaximum = max(frameMaximum, value)
				histogram[value]++
				sampleSum += float64(value)
				sampleSquareSum += float64(value) * float64(value)
			}
		}
		if frameIndex > 0 {
			changed := 0
			for index, value := range samples {
				if value != previousSamples[index] {
					changed++
				}
			}
			if changed == 0 {
				return Statistics{}, fmt.Errorf("sampled pixels in camera frames %d and %d are identical", frameIndex-1, frameIndex)
			}
			ratio := float64(changed) / float64(len(samples))
			minimumTemporalChange = min(minimumTemporalChange, ratio)
		}
		statistics.SampleCount += int64(len(samples))
		statistics.SampleMinimum = min(statistics.SampleMinimum, frameMinimum)
		statistics.SampleMaximum = max(statistics.SampleMaximum, frameMaximum)
		statistics.Frames = append(statistics.Frames, FrameStatistics{
			Index: frameIndex, SHA256: hex.EncodeToString(digest[:]),
			SampleMinimum: frameMinimum, SampleMaximum: frameMaximum,
		})
		previousSamples = samples
		previousDigest = digest
	}
	trailing := make([]byte, 1)
	if count, err := reader.Read(trailing); err != nil && err != io.EOF {
		return Statistics{}, fmt.Errorf("check camera capture boundary: %w", err)
	} else if count != 0 {
		return Statistics{}, fmt.Errorf("camera capture contains data after the expected final frame")
	}
	statistics.MinimumTemporalChange = minimumTemporalChange
	statistics.DistinctCodes = distinctCodes(histogram)
	statistics.Mean = sampleSum / float64(statistics.SampleCount)
	variance := max(0, sampleSquareSum/float64(statistics.SampleCount)-statistics.Mean*statistics.Mean)
	statistics.StandardDeviation = math.Sqrt(variance)
	statistics.EntropyBits = histogramEntropy(histogram, statistics.SampleCount)
	if int(statistics.SampleMaximum)-int(statistics.SampleMinimum) < 8 {
		return Statistics{}, fmt.Errorf("sampled camera RAW10 range is less than 8 codes")
	}
	if statistics.DistinctCodes < 8 {
		return Statistics{}, fmt.Errorf("camera capture has fewer than 8 distinct sampled RAW10 codes")
	}
	if statistics.StandardDeviation < 1.0 {
		return Statistics{}, fmt.Errorf("sampled camera RAW10 standard deviation is below 1 code")
	}
	if statistics.EntropyBits < 1.0 {
		return Statistics{}, fmt.Errorf("sampled camera RAW10 entropy is below 1 bit")
	}
	return statistics, nil
}

// decodeRAW10Group expands four high bytes and their packed two-bit tails.
func decodeRAW10Group(group []byte) [4]uint16 {
	low := group[4]
	return [4]uint16{
		uint16(group[0])<<2 | uint16(low&0x03),
		uint16(group[1])<<2 | uint16((low>>2)&0x03),
		uint16(group[2])<<2 | uint16((low>>4)&0x03),
		uint16(group[3])<<2 | uint16((low>>6)&0x03),
	}
}

// distinctCodes counts non-empty bins in one fixed ten-bit histogram.
func distinctCodes(histogram []int64) int {
	distinct := 0
	for _, count := range histogram {
		if count != 0 {
			distinct++
		}
	}
	return distinct
}

// histogramEntropy computes Shannon entropy from one sampled-code histogram.
func histogramEntropy(histogram []int64, total int64) float64 {
	var entropy float64
	for _, count := range histogram {
		if count == 0 {
			continue
		}
		probability := float64(count) / float64(total)
		entropy -= probability * math.Log2(probability)
	}
	return entropy
}
