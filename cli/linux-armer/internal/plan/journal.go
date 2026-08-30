package plan

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Journal records verified execution results without mutating the plan.
type Journal struct {
	// SchemaVersion selects the journal serialisation contract.
	SchemaVersion int `json:"schema_version"`
	// Operation associates the evidence with the plan that produced it.
	Operation string `json:"operation"`
	// Records contains successful checkpoints in completion order.
	Records []StepRecord `json:"records"`
	// Output identifies the final published artefact when one exists.
	Output *OutputRecord `json:"output,omitempty"`
}

// StepRecord captures when one planned step completed and the verified digests
// available at that resource-clean boundary.
type StepRecord struct {
	// StepID references the stable ID in the operation plan.
	StepID string `json:"step_id"`
	// CompletedAt records checkpoint completion in UTC.
	CompletedAt time.Time `json:"completed_at"`
	// Digests binds named intermediate artefacts to the bytes that were verified.
	Digests map[string]string `json:"digests,omitempty"`
}

// OutputRecord identifies the final artefact published by an operation.
type OutputRecord struct {
	// Path is the destination recorded by the workflow.
	Path string `json:"path"`
	// SHA256 identifies the complete published bytes.
	SHA256 string `json:"sha256"`
	// Size is the artefact length in bytes.
	Size int64 `json:"size_bytes"`
}

// NewJournal starts an empty journal for an operation using the current schema.
func NewJournal(operation string) *Journal {
	return &Journal{SchemaVersion: SchemaVersion, Operation: operation, Records: []StepRecord{}}
}

// Complete appends a successful step checkpoint with a UTC timestamp. Callers
// persist that evidence explicitly with Save after reaching a clean boundary.
func (j *Journal) Complete(stepID string, digests map[string]string) {
	j.Records = append(j.Records, StepRecord{
		StepID:      stepID,
		CompletedAt: time.Now().UTC(),
		Digests:     digests,
	})
}

// Save serialises the journal through a random, exclusively created sibling and
// atomically replaces its destination on a resource-clean boundary.
func (j *Journal) Save(path string) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return fmt.Errorf("create journal directory: %w", err)
	}
	file, err := os.CreateTemp(directory, "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return fmt.Errorf("create journal: %w", err)
	}
	temporary := file.Name()
	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	encodeErr := encoder.Encode(j)
	modeErr := file.Chmod(0o644)
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(encodeErr, modeErr, syncErr, closeErr); err != nil {
		_ = os.Remove(temporary)
		return fmt.Errorf("write journal: %w", err)
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return fmt.Errorf("publish journal: %w", err)
	}
	return nil
}
