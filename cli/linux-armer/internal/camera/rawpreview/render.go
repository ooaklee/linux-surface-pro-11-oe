package rawpreview

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"regexp"
	"sort"
	"strings"
)

// raw10BusCodePattern finds only complete supported media-bus tokens.
var raw10BusCodePattern = regexp.MustCompile(`\bS(?:BGGR|GBRG|GRBG|RGGB)10_1X10\b`)

// topologySuffixes are searched in post-configuration then pre-configuration order.
var topologySuffixes = []string{".media-after.txt", ".media-before.txt"}

// Render converts one exact IMX681 packed-RAW10 frame to a private PNG.
func Render(options Options) (Result, error) {
	return render(options, imx681Layout)
}

// render applies the renderer to a validated layout so focused tests can use
// small frames without weakening the fixed production contract.
func render(options Options, layout frameLayout) (Result, error) {
	if err := validateLayout(layout); err != nil {
		return Result{}, err
	}
	if strings.TrimSpace(options.InputPath) == "" {
		return Result{}, errors.New("RAW input path must not be empty")
	}
	if strings.TrimSpace(options.OutputPath) == "" {
		return Result{}, errors.New("PNG output path must not be empty")
	}
	if options.InputPath == options.OutputPath {
		return Result{}, errors.New("RAW input and PNG output paths must differ")
	}
	if options.FrameIndex < 0 {
		return Result{}, errors.New("frame index must not be negative")
	}
	order, err := ParseBayerOrder(string(options.BayerOrder))
	if err != nil {
		return Result{}, err
	}
	if order == BayerAuto {
		order, err = discoverBayerOrder(options.InputPath)
		if err != nil {
			return Result{}, err
		}
	}
	frame, err := readFrame(options.InputPath, options.FrameIndex, layout)
	if err != nil {
		return Result{}, err
	}
	rgb, histogram, err := demosaicHalf(frame, order, layout)
	if err != nil {
		return Result{}, err
	}
	lookup, low, high := makeLookup(histogram, options.Linear)
	pngBytes, err := encodePNG(rgb, lookup, order, options.Linear, layout)
	if err != nil {
		return Result{}, err
	}
	if err := writeExclusivePrivate(options.OutputPath, pngBytes); err != nil {
		return Result{}, err
	}
	mapping := fmt.Sprintf("preview stretch %d..%d", low, high)
	if options.Linear {
		mapping = "linear 0..1023"
	}
	return Result{
		InputPath: options.InputPath, OutputPath: options.OutputPath,
		FrameIndex: options.FrameIndex, BayerOrder: order, Mapping: mapping,
		LowerCode: low, UpperCode: high, Width: layout.width / 2,
		Height: layout.height / 2, Bytes: int64(len(pngBytes)),
	}, nil
}

// validateLayout checks the arithmetic and packed-RAW10 geometry used by the parser.
func validateLayout(layout frameLayout) error {
	if layout.width <= 0 || layout.height <= 0 || layout.width%4 != 0 || layout.height%2 != 0 {
		return errors.New("RAW10 layout must have a positive width divisible by four and an even positive height")
	}
	expectedStride := layout.width * 5 / 4
	if layout.stride != expectedStride {
		return fmt.Errorf("RAW10 stride is %d bytes; expected %d", layout.stride, expectedStride)
	}
	if layout.frameSize != int64(layout.stride)*int64(layout.height) {
		return errors.New("RAW10 frame size does not match stride multiplied by height")
	}
	return nil
}

// discoverBayerOrder extracts exactly one supported order from a bounded,
// regular validator topology sidecar.
func discoverBayerOrder(rawPath string) (BayerOrder, error) {
	for _, suffix := range topologySuffixes {
		topologyPath := rawPath + suffix
		topology, found, err := readOptionalRegularFile(topologyPath, maximumTopologyBytes)
		if err != nil {
			return "", err
		}
		if !found {
			continue
		}
		matches := raw10BusCodePattern.FindAll(topology, -1)
		orders := make(map[BayerOrder]struct{}, len(matches))
		for _, match := range matches {
			orders[busCodeToBayer[string(match)]] = struct{}{}
		}
		if len(orders) == 1 {
			for order := range orders {
				return order, nil
			}
		}
		if len(orders) > 1 {
			values := make([]string, 0, len(orders))
			for order := range orders {
				values = append(values, string(order))
			}
			sort.Strings(values)
			return "", fmt.Errorf("%s contains ambiguous RAW10 Bayer orders: %s", topologyPath, strings.Join(values, ", "))
		}
	}
	return "", errors.New("could not discover one RAW10 Bayer order from validator sidecars; pass an explicit order after inspecting the saved topology")
}

// readOptionalRegularFile reads at most limit bytes without following a known
// symlink and distinguishes a missing optional sidecar from invalid evidence.
func readOptionalRegularFile(path string, limit int64) ([]byte, bool, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("inspect topology sidecar %s: %w", path, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, false, fmt.Errorf("topology sidecar is not a regular non-symlink file: %s", path)
	}
	if info.Size() > limit {
		return nil, false, fmt.Errorf("topology sidecar exceeds the %d-byte limit: %s", limit, path)
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, false, fmt.Errorf("open topology sidecar %s: %w", path, err)
	}
	defer file.Close()
	openedInfo, err := file.Stat()
	if err != nil {
		return nil, false, fmt.Errorf("inspect opened topology sidecar %s: %w", path, err)
	}
	if !openedInfo.Mode().IsRegular() || !os.SameFile(info, openedInfo) {
		return nil, false, fmt.Errorf("topology sidecar changed while being opened: %s", path)
	}
	contents, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, false, fmt.Errorf("read topology sidecar %s: %w", path, err)
	}
	if int64(len(contents)) > limit {
		return nil, false, fmt.Errorf("topology sidecar exceeds the %d-byte limit: %s", limit, path)
	}
	return contents, true, nil
}

// readFrame reads one exact frame from a stable regular capture file.
func readFrame(path string, frameIndex int, layout frameLayout) ([]byte, error) {
	if frameIndex < 0 {
		return nil, errors.New("frame index must not be negative")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("inspect RAW input %s: %w", path, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("RAW input is not a regular non-symlink file: %s", path)
	}
	if info.Size() <= 0 || info.Size()%layout.frameSize != 0 {
		return nil, fmt.Errorf("RAW input size is %d bytes; expected a positive multiple of %d", info.Size(), layout.frameSize)
	}
	frameCount := info.Size() / layout.frameSize
	if int64(frameIndex) >= frameCount {
		return nil, fmt.Errorf("frame %d is outside the available range 0..%d", frameIndex, frameCount-1)
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open RAW input %s: %w", path, err)
	}
	defer file.Close()
	openedInfo, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("inspect opened RAW input %s: %w", path, err)
	}
	if !openedInfo.Mode().IsRegular() || !os.SameFile(info, openedInfo) || openedInfo.Size() != info.Size() {
		return nil, fmt.Errorf("RAW input changed while being opened: %s", path)
	}
	frame := make([]byte, int(layout.frameSize))
	offset := int64(frameIndex) * layout.frameSize
	read, err := file.ReadAt(frame, offset)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("read RAW frame %d: %w", frameIndex, err)
	}
	if int64(read) != layout.frameSize {
		return nil, fmt.Errorf("RAW frame %d became short while it was being read", frameIndex)
	}
	finalInfo, err := file.Stat()
	if err != nil || finalInfo.Size() != openedInfo.Size() {
		return nil, fmt.Errorf("RAW input changed while frame %d was being read", frameIndex)
	}
	return frame, nil
}

// unpackRow expands one V4L2 packed-RAW10 row into 10-bit sample codes.
func unpackRow(frame []byte, rowIndex int, layout frameLayout) ([]uint16, error) {
	start := rowIndex * layout.stride
	end := start + layout.stride
	if rowIndex < 0 || start < 0 || end > len(frame) {
		return nil, fmt.Errorf("RAW row %d is outside the frame", rowIndex)
	}
	row := frame[start:end]
	pixels := make([]uint16, 0, layout.width)
	for offset := 0; offset < layout.stride; offset += 5 {
		low := row[offset+4]
		pixels = append(pixels,
			uint16(row[offset])<<2|uint16(low&0x03),
			uint16(row[offset+1])<<2|uint16((low>>2)&0x03),
			uint16(row[offset+2])<<2|uint16((low>>4)&0x03),
			uint16(row[offset+3])<<2|uint16((low>>6)&0x03),
		)
	}
	if len(pixels) != layout.width {
		return nil, fmt.Errorf("RAW row %d decoded to %d pixels; expected %d", rowIndex, len(pixels), layout.width)
	}
	return pixels, nil
}

// demosaicHalf reduces each Bayer cell to one RGB pixel and records the green histogram.
func demosaicHalf(frame []byte, order BayerOrder, layout frameLayout) ([]uint16, [1024]uint64, error) {
	cells, ok := bayerCells[order]
	if !ok {
		return nil, [1024]uint64{}, fmt.Errorf("unsupported Bayer order %q", order)
	}
	if int64(len(frame)) != layout.frameSize {
		return nil, [1024]uint64{}, fmt.Errorf("RAW frame contains %d bytes; expected %d", len(frame), layout.frameSize)
	}
	redIndex, blueIndex := -1, -1
	greenIndices := [2]int{-1, -1}
	greenCount := 0
	for index, cell := range cells {
		switch cell {
		case 'R':
			redIndex = index
		case 'B':
			blueIndex = index
		case 'G':
			greenIndices[greenCount] = index
			greenCount++
		}
	}
	rgb := make([]uint16, 0, layout.width*layout.height*3/4)
	var histogram [1024]uint64
	for rowIndex := 0; rowIndex < layout.height; rowIndex += 2 {
		row0, err := unpackRow(frame, rowIndex, layout)
		if err != nil {
			return nil, histogram, err
		}
		row1, err := unpackRow(frame, rowIndex+1, layout)
		if err != nil {
			return nil, histogram, err
		}
		for column := 0; column < layout.width; column += 2 {
			values := [4]uint16{row0[column], row0[column+1], row1[column], row1[column+1]}
			green := (values[greenIndices[0]] + values[greenIndices[1]] + 1) / 2
			rgb = append(rgb, values[redIndex], green, values[blueIndex])
			histogram[green]++
		}
	}
	return rgb, histogram, nil
}

// percentileBounds returns the nearest-rank first and ninety-ninth percentiles.
func percentileBounds(histogram [1024]uint64) (int, int) {
	var total uint64
	for _, count := range histogram {
		total += count
	}
	lowerRank := (total + 99) / 100
	upperRank := (total*99 + 99) / 100
	if lowerRank < 1 {
		lowerRank = 1
	}
	if upperRank < 1 {
		upperRank = 1
	}
	low := 0
	high := 1023
	var cumulative uint64
	for code, count := range histogram {
		cumulative += count
		if cumulative >= lowerRank {
			low = code
			break
		}
	}
	cumulative = 0
	for code, count := range histogram {
		cumulative += count
		if cumulative >= upperRank {
			high = code
			break
		}
	}
	if high <= low {
		return 0, 1023
	}
	return low, high
}

// makeLookup maps all ten-bit codes to deterministic eight-bit preview values.
func makeLookup(histogram [1024]uint64, linear bool) ([1024]byte, int, int) {
	var lookup [1024]byte
	if linear {
		for code := range lookup {
			lookup[code] = byte(math.RoundToEven(float64(code) * 255 / 1023))
		}
		return lookup, 0, 1023
	}
	low, high := percentileBounds(histogram)
	span := float64(high - low)
	for code := range lookup {
		ratio := float64(code-low) / span
		ratio = math.Max(0, math.Min(1, ratio))
		lookup[code] = byte(math.RoundToEven(255 * math.Pow(ratio, 0.45)))
	}
	return lookup, low, high
}

// writeExclusivePrivate creates one new output, requests mode 0600 on hosts
// with Unix permissions, and removes the same partial file after its identity
// is established if writing or flushing fails.
func writeExclusivePrivate(path string, contents []byte) (returnErr error) {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("create new PNG output %s: %w", path, err)
	}
	createdInfo, statErr := file.Stat()
	if statErr != nil {
		_ = file.Close()
		return fmt.Errorf("inspect new PNG output %s: %w", path, statErr)
	}
	complete := false
	closed := false
	defer func() {
		if !closed {
			returnErr = errors.Join(returnErr, file.Close())
		}
		if !complete {
			returnErr = errors.Join(returnErr, removeIfSameFile(path, createdInfo))
		}
	}()
	if _, err := io.Copy(file, bytes.NewReader(contents)); err != nil {
		return fmt.Errorf("write PNG output %s: %w", path, err)
	}
	if err := file.Sync(); err != nil {
		return fmt.Errorf("flush PNG output %s: %w", path, err)
	}
	if err := file.Close(); err != nil {
		closed = true
		return fmt.Errorf("close PNG output %s: %w", path, err)
	}
	closed = true
	complete = true
	return nil
}

// removeIfSameFile removes only the partial output created by this operation.
func removeIfSameFile(path string, expected os.FileInfo) error {
	current, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect partial PNG output %s: %w", path, err)
	}
	if current.Mode()&os.ModeSymlink != 0 || !os.SameFile(current, expected) {
		return fmt.Errorf("refuse to remove a replaced partial PNG output: %s", path)
	}
	if err := os.Remove(path); err != nil {
		return fmt.Errorf("remove partial PNG output %s: %w", path, err)
	}
	return nil
}
