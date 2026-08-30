package release

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

// MarshalPortableReceipt serialises a location-independent bundle receipt in
// the canonical form written by the release downloader.
func MarshalPortableReceipt(receipt Bundle) ([]byte, error) {
	if strings.TrimSpace(receipt.Component) == "" || strings.TrimSpace(receipt.Component) != receipt.Component {
		return nil, errors.New("portable userspace receipt component must be a trimmed non-empty value")
	}
	if strings.TrimSpace(receipt.Repository) == "" || strings.TrimSpace(receipt.Repository) != receipt.Repository {
		return nil, errors.New("portable userspace receipt repository must be a trimmed non-empty value")
	}
	if strings.TrimSpace(receipt.Release) == "" || strings.TrimSpace(receipt.Release) != receipt.Release {
		return nil, errors.New("portable userspace receipt release must be a trimmed non-empty value")
	}
	if receipt.Directory != "." {
		return nil, errors.New("portable userspace receipt directory must be the current directory")
	}
	if receipt.Files == nil {
		return nil, errors.New("portable userspace receipt files must be an explicit array")
	}
	seen := make(map[string]bool, len(receipt.Files))
	for _, file := range receipt.Files {
		if err := validateAssetName(file.Name); err != nil {
			return nil, err
		}
		if seen[file.Name] {
			return nil, fmt.Errorf("duplicate userspace bundle file %q", file.Name)
		}
		seen[file.Name] = true
		if file.Path != file.Name {
			return nil, fmt.Errorf("portable userspace receipt path for %s must be its flat filename", file.Name)
		}
	}
	content, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("encode portable userspace receipt: %w", err)
	}
	return append(content, '\n'), nil
}

// ValidateReceiptJSONShape rejects duplicate, mis-cased, and unknown receipt
// keys before Go's case-insensitive typed JSON decoder sees the document.
func ValidateReceiptJSONShape(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '{' {
		return errors.New("userspace bundle manifest must be a JSON object")
	}
	allowed := map[string]bool{
		"component":  false,
		"repository": false,
		"release":    false,
		"directory":  false,
		"files":      false,
	}
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return err
		}
		key, ok := keyToken.(string)
		if !ok {
			return errors.New("userspace bundle manifest contains a non-string object key")
		}
		seen, known := allowed[key]
		if !known {
			return fmt.Errorf("unknown field %q", key)
		}
		if seen {
			return fmt.Errorf("duplicate field %q", key)
		}
		allowed[key] = true
		if key == "files" {
			if err := validateReceiptFilesJSON(decoder); err != nil {
				return err
			}
			continue
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return err
		}
	}
	if _, err := decoder.Token(); err != nil {
		return err
	}
	if token, err := decoder.Token(); !errors.Is(err, io.EOF) {
		if err != nil {
			return err
		}
		return fmt.Errorf("userspace bundle manifest contains trailing JSON value %v", token)
	}
	return nil
}

// validateReceiptFilesJSON applies exact and duplicate-key checks to every
// file record while leaving value type checks to the typed decoder.
func validateReceiptFilesJSON(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '[' {
		return errors.New("userspace bundle manifest files must be a JSON array")
	}
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		if delimiter, ok := token.(json.Delim); !ok || delimiter != '{' {
			return errors.New("userspace bundle manifest file must be a JSON object")
		}
		allowed := map[string]bool{
			"name":     false,
			"path":     false,
			"sha256":   false,
			"size":     false,
			"verified": false,
		}
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok {
				return errors.New("userspace bundle manifest file contains a non-string object key")
			}
			seen, known := allowed[key]
			if !known {
				return fmt.Errorf("unknown file field %q", key)
			}
			if seen {
				return fmt.Errorf("duplicate file field %q", key)
			}
			allowed[key] = true
			var value json.RawMessage
			if err := decoder.Decode(&value); err != nil {
				return err
			}
		}
		if _, err := decoder.Token(); err != nil {
			return err
		}
	}
	_, err = decoder.Token()
	return err
}
