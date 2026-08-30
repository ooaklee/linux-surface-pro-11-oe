package release

import (
	"strings"
	"testing"
)

// TestValidateReceiptJSONShapeRejectsAmbiguousKeys verifies that both callers
// share exact, case-sensitive, duplicate-rejecting receipt parsing.
func TestValidateReceiptJSONShapeRejectsAmbiguousKeys(t *testing.T) {
	valid := `{"component":"test","repository":"owner/repository","release":"test-v1","directory":".","files":[{"name":"payload","path":"payload","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1,"verified":true}]}`
	if err := ValidateReceiptJSONShape([]byte(valid)); err != nil {
		t.Fatalf("valid receipt shape: %v", err)
	}
	for _, testCase := range []struct {
		name    string
		content string
		message string
	}{
		{
			name:    "duplicate top-level field",
			content: strings.Replace(valid, `"component":"test"`, `"component":"other","component":"test"`, 1),
			message: "duplicate field",
		},
		{
			name:    "mis-cased top-level field",
			content: strings.Replace(valid, `"component"`, `"Component"`, 1),
			message: "unknown field",
		},
		{
			name:    "duplicate file field",
			content: strings.Replace(valid, `"name":"payload"`, `"name":"other","name":"payload"`, 1),
			message: "duplicate file field",
		},
		{
			name:    "mis-cased file field",
			content: strings.Replace(valid, `"verified"`, `"Verified"`, 1),
			message: "unknown file field",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			err := ValidateReceiptJSONShape([]byte(testCase.content))
			if err == nil || !strings.Contains(err.Error(), testCase.message) {
				t.Fatalf("error = %v, want %q rejection", err, testCase.message)
			}
		})
	}
}
