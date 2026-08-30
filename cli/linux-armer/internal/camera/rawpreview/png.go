package rawpreview

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"io"
)

// pngSignature is the fixed eight-byte PNG file signature.
var pngSignature = []byte{'\x89', 'P', 'N', 'G', '\r', '\n', '\x1a', '\n'}

// encodePNG emits one repeatable, true-colour, non-interlaced PNG with a short
// description of the Bayer order and brightness mapping.
func encodePNG(rgb []uint16, lookup [1024]byte, order BayerOrder, linear bool, layout frameLayout) ([]byte, error) {
	outputWidth := layout.width / 2
	outputHeight := layout.height / 2
	expectedValues := outputWidth * outputHeight * 3
	if len(rgb) != expectedValues {
		return nil, fmt.Errorf("demosaic produced %d values; expected %d", len(rgb), expectedValues)
	}
	scanlines := make([]byte, 0, outputHeight*(1+outputWidth*3))
	valueIndex := 0
	for row := 0; row < outputHeight; row++ {
		scanlines = append(scanlines, 0)
		rowEnd := valueIndex + outputWidth*3
		for _, value := range rgb[valueIndex:rowEnd] {
			if value > 1023 {
				return nil, fmt.Errorf("demosaic value %d exceeds the ten-bit range", value)
			}
			scanlines = append(scanlines, lookup[value])
		}
		valueIndex = rowEnd
	}
	var compressed bytes.Buffer
	compressor, err := zlib.NewWriterLevel(&compressed, 6)
	if err != nil {
		return nil, fmt.Errorf("construct PNG compressor: %w", err)
	}
	if _, err := compressor.Write(scanlines); err != nil {
		_ = compressor.Close()
		return nil, fmt.Errorf("compress PNG pixels: %w", err)
	}
	if err := compressor.Close(); err != nil {
		return nil, fmt.Errorf("finish PNG compression: %w", err)
	}
	description := fmt.Sprintf("SP11 IMX681 inspection preview; Bayer=%s; mapping=1-99 percentile gamma 0.45", order)
	if linear {
		description = fmt.Sprintf("SP11 IMX681 inspection preview; Bayer=%s; mapping=linear", order)
	}
	var output bytes.Buffer
	output.Write(pngSignature)
	header := make([]byte, 13)
	binary.BigEndian.PutUint32(header[0:4], uint32(outputWidth))
	binary.BigEndian.PutUint32(header[4:8], uint32(outputHeight))
	header[8] = 8
	header[9] = 2
	if err := writePNGChunk(&output, "IHDR", header); err != nil {
		return nil, err
	}
	if err := writePNGChunk(&output, "tEXt", append([]byte("Description\x00"), []byte(description)...)); err != nil {
		return nil, err
	}
	if err := writePNGChunk(&output, "IDAT", compressed.Bytes()); err != nil {
		return nil, err
	}
	if err := writePNGChunk(&output, "IEND", nil); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

// writePNGChunk appends one length-prefixed PNG chunk and its CRC-32 checksum.
func writePNGChunk(writer io.Writer, kind string, payload []byte) error {
	if len(kind) != 4 {
		return fmt.Errorf("PNG chunk kind %q is not four bytes", kind)
	}
	if len(payload) > int(^uint32(0)) {
		return fmt.Errorf("PNG chunk %s is too large", kind)
	}
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], uint32(len(payload)))
	if _, err := writer.Write(length[:]); err != nil {
		return fmt.Errorf("write PNG %s length: %w", kind, err)
	}
	kindBytes := []byte(kind)
	if _, err := writer.Write(kindBytes); err != nil {
		return fmt.Errorf("write PNG %s kind: %w", kind, err)
	}
	if _, err := writer.Write(payload); err != nil {
		return fmt.Errorf("write PNG %s payload: %w", kind, err)
	}
	checksum := crc32.NewIEEE()
	_, _ = checksum.Write(kindBytes)
	_, _ = checksum.Write(payload)
	var crc [4]byte
	binary.BigEndian.PutUint32(crc[:], checksum.Sum32())
	if _, err := writer.Write(crc[:]); err != nil {
		return fmt.Errorf("write PNG %s checksum: %w", kind, err)
	}
	return nil
}
