package releaseprep

import (
	"encoding/json"
	"errors"
	"io"
)

// strictJSONDecoder is the narrow decoder behaviour used for public contracts.
type strictJSONDecoder interface {
	// Decode reads one JSON value.
	Decode(any) error
}

// newStrictJSONDecoder constructs a decoder that rejects unknown fields.
func newStrictJSONDecoder(reader io.Reader) *json.Decoder {
	decoder := json.NewDecoder(reader)
	decoder.DisallowUnknownFields()
	return decoder
}

// requireJSONEOF rejects a second JSON value or non-whitespace trailing bytes.
func requireJSONEOF(decoder strictJSONDecoder) error {
	var trailing any
	err := decoder.Decode(&trailing)
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err == nil {
		return errors.New("JSON contains more than one value")
	}
	return err
}
