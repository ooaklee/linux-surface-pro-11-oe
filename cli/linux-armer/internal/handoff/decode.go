package handoff

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"
	"strings"
	"unicode/utf8"
)

// utf8ByteOrderMark is forbidden because the contract requires portable UTF-8
// without an encoding signature.
var utf8ByteOrderMark = []byte{0xef, 0xbb, 0xbf}

// Decode reads one bounded Windows hand-off document, checks its exact JSON
// shape with a token decoder, decodes its types, and validates its semantics.
func Decode(reader io.Reader) (Contract, error) {
	if reader == nil {
		return Contract{}, errors.New("decode Windows hand-off: reader is nil")
	}
	data, err := io.ReadAll(io.LimitReader(reader, MaximumDocumentSize+1))
	if err != nil {
		return Contract{}, fmt.Errorf("read Windows hand-off: %w", err)
	}
	if len(data) > MaximumDocumentSize {
		return Contract{}, fmt.Errorf("Windows hand-off exceeds %d bytes", MaximumDocumentSize)
	}
	if bytes.HasPrefix(data, utf8ByteOrderMark) {
		return Contract{}, errors.New("decode Windows hand-off JSON: UTF-8 byte-order mark is not allowed")
	}
	if !utf8.Valid(data) {
		return Contract{}, errors.New("decode Windows hand-off JSON: input is not valid UTF-8")
	}
	if err := validateContractJSONShape(data); err != nil {
		return Contract{}, err
	}

	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var contract Contract
	if err := decoder.Decode(&contract); err != nil {
		return Contract{}, fmt.Errorf("decode Windows hand-off JSON: %w", err)
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return Contract{}, errors.New("decode Windows hand-off JSON: multiple JSON values are not allowed")
		}
		return Contract{}, fmt.Errorf("decode Windows hand-off JSON after first value: %w", err)
	}
	if err := Validate(contract); err != nil {
		return Contract{}, err
	}
	return contract, nil
}

// validateContractJSONShape applies exact, case-sensitive, duplicate-free, and
// non-null field contracts throughout the complete document.
func validateContractJSONShape(data []byte) error {
	return validateJSONValueShape(data, reflect.TypeOf(Contract{}), "Windows hand-off")
}

// validateJSONValueShape recursively checks container types and forbids null at
// every field that is present, including optional pointer fields.
func validateJSONValueShape(data []byte, target reflect.Type, location string) error {
	trimmed := bytes.TrimSpace(data)
	if bytes.Equal(trimmed, []byte("null")) {
		return fmt.Errorf("decode %s JSON: value must not be null", location)
	}
	for target.Kind() == reflect.Pointer {
		target = target.Elem()
	}
	switch target.Kind() {
	case reflect.Struct:
		return validateJSONObjectShape(trimmed, target, location)
	case reflect.Slice, reflect.Array:
		return validateJSONArrayShape(trimmed, target.Elem(), location)
	default:
		return nil
	}
}

// validateJSONObjectShape rejects unknown, mis-cased, duplicate, missing, and
// recursively malformed object fields.
func validateJSONObjectShape(data []byte, target reflect.Type, location string) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil {
		return fmt.Errorf("decode %s JSON object: %w", location, err)
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '{' {
		return fmt.Errorf("decode %s JSON: value must be an object", location)
	}

	fields := make(map[string]reflect.StructField)
	required := make(map[string]bool)
	for index := 0; index < target.NumField(); index++ {
		field := target.Field(index)
		if field.PkgPath != "" {
			continue
		}
		name, optional, ignored := shapeFieldContract(field)
		if ignored {
			continue
		}
		fields[name] = field
		if !optional {
			required[name] = true
		}
	}

	seen := make(map[string]bool)
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return fmt.Errorf("decode %s JSON field: %w", location, err)
		}
		key, ok := keyToken.(string)
		if !ok {
			return fmt.Errorf("decode %s JSON: object field name is not a string", location)
		}
		if seen[key] {
			return fmt.Errorf("decode %s JSON: duplicate field %q", location, key)
		}
		seen[key] = true
		field, found := fields[key]
		if !found {
			return fmt.Errorf("decode %s JSON: unknown or mis-cased field %q", location, key)
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return fmt.Errorf("decode %s JSON field %q: %w", location, key, err)
		}
		if err := validateJSONValueShape(value, field.Type, location+"."+key); err != nil {
			return err
		}
	}
	if _, err := decoder.Token(); err != nil {
		return fmt.Errorf("decode %s JSON object end: %w", location, err)
	}
	for name := range required {
		if !seen[name] {
			return fmt.Errorf("decode %s JSON: required field %q is missing", location, name)
		}
	}
	return nil
}

// validateJSONArrayShape verifies an array container and recursively checks
// every member against its exact element contract.
func validateJSONArrayShape(data []byte, element reflect.Type, location string) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil {
		return fmt.Errorf("decode %s JSON array: %w", location, err)
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '[' {
		return fmt.Errorf("decode %s JSON: value must be an array", location)
	}
	index := 0
	for decoder.More() {
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return fmt.Errorf("decode %s JSON array member: %w", location, err)
		}
		if err := validateJSONValueShape(value, element, fmt.Sprintf("%s[%d]", location, index)); err != nil {
			return err
		}
		index++
	}
	if _, err := decoder.Token(); err != nil {
		return fmt.Errorf("decode %s JSON array end: %w", location, err)
	}
	return nil
}

// shapeFieldContract returns the exact JSON name and required state declared by
// one exported structure field.
func shapeFieldContract(field reflect.StructField) (name string, optional bool, ignored bool) {
	tag := field.Tag.Get("json")
	parts := strings.Split(tag, ",")
	if len(parts) > 0 && parts[0] == "-" {
		return "", false, true
	}
	name = field.Name
	if len(parts) > 0 && parts[0] != "" {
		name = parts[0]
	}
	for _, option := range parts[1:] {
		if option == "omitempty" {
			optional = true
		}
	}
	return name, optional, false
}
