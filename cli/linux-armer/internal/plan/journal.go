package plan

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Journal records verified execution results without mutating the plan.
type Journal struct {
	SchemaVersion int           `json:"schema_version"`
	Operation     string        `json:"operation"`
	Records       []StepRecord  `json:"records"`
	Output        *OutputRecord `json:"output,omitempty"`
}

type StepRecord struct {
	StepID      string            `json:"step_id"`
	CompletedAt time.Time         `json:"completed_at"`
	Digests     map[string]string `json:"digests,omitempty"`
}

type OutputRecord struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size_bytes"`
}

func NewJournal(operation string) *Journal {
	return &Journal{SchemaVersion: SchemaVersion, Operation: operation, Records: []StepRecord{}}
}

func (j *Journal) Complete(stepID string, digests map[string]string) {
	j.Records = append(j.Records, StepRecord{
		StepID:      stepID,
		CompletedAt: time.Now().UTC(),
		Digests:     digests,
	})
}

// Save atomically replaces the journal on a resource-clean boundary.
func (j *Journal) Save(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create journal directory: %w", err)
	}
	temporary := path + ".tmp"
	file, err := os.OpenFile(temporary, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("create journal: %w", err)
	}
	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	encodeErr := encoder.Encode(j)
	closeErr := file.Close()
	if encodeErr != nil {
		_ = os.Remove(temporary)
		return fmt.Errorf("encode journal: %w", encodeErr)
	}
	if closeErr != nil {
		_ = os.Remove(temporary)
		return fmt.Errorf("close journal: %w", closeErr)
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return fmt.Errorf("publish journal: %w", err)
	}
	return nil
}
