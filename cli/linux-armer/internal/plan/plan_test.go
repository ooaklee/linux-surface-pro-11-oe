package plan

import (
	"bytes"
	"strings"
	"testing"
)

func TestNewRejectsDuplicateStepIDs(t *testing.T) {
	t.Parallel()
	_, err := New("image.create",
		Step{ID: "fetch", Kind: "fetch", Description: "Fetch source"},
		Step{ID: "fetch", Kind: "verify", Description: "Verify source"},
	)
	if err == nil || !strings.Contains(err.Error(), "duplicate id") {
		t.Fatalf("expected duplicate ID error, got %v", err)
	}
}

func TestWriteJSONIsDeterministic(t *testing.T) {
	t.Parallel()
	p, err := New("image.create", Step{
		ID:          "fetch-source",
		Kind:        "fetch",
		Description: "Fetch source image",
		Inputs:      map[string]string{"url": "https://example.test/image.iso", "id": "ubuntu"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var first, second bytes.Buffer
	if err := p.WriteJSON(&first); err != nil {
		t.Fatal(err)
	}
	if err := p.WriteJSON(&second); err != nil {
		t.Fatal(err)
	}
	if first.String() != second.String() {
		t.Fatalf("plan output changed:\n%s\n%s", first.String(), second.String())
	}
}
