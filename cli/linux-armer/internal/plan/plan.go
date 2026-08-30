// Package plan describes deterministic work before it is executed.
package plan

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"
)

const SchemaVersion = 1

// Step is one idempotent unit in an operation plan.
type Step struct {
	ID          string            `json:"id"`
	Kind        string            `json:"kind"`
	Description string            `json:"description"`
	Inputs      map[string]string `json:"inputs,omitempty"`
}

// Plan is an immutable, serializable description of an operation.
type Plan struct {
	SchemaVersion int    `json:"schema_version"`
	Operation     string `json:"operation"`
	Steps         []Step `json:"steps"`
}

// New validates and copies the supplied steps.
func New(operation string, steps ...Step) (Plan, error) {
	p := Plan{
		SchemaVersion: SchemaVersion,
		Operation:     strings.TrimSpace(operation),
		Steps:         make([]Step, len(steps)),
	}
	for i, step := range steps {
		p.Steps[i] = cloneStep(step)
	}
	if err := p.Validate(); err != nil {
		return Plan{}, err
	}
	return p, nil
}

// Validate checks stable IDs, supported schema, and required descriptions.
func (p Plan) Validate() error {
	var problems []error
	if p.SchemaVersion != SchemaVersion {
		problems = append(problems, fmt.Errorf("unsupported plan schema version %d", p.SchemaVersion))
	}
	if strings.TrimSpace(p.Operation) == "" {
		problems = append(problems, errors.New("operation is required"))
	}
	if len(p.Steps) == 0 {
		problems = append(problems, errors.New("at least one step is required"))
	}
	seen := make(map[string]struct{}, len(p.Steps))
	for i, step := range p.Steps {
		prefix := fmt.Sprintf("step %d", i+1)
		if strings.TrimSpace(step.ID) == "" {
			problems = append(problems, fmt.Errorf("%s: id is required", prefix))
		} else if _, exists := seen[step.ID]; exists {
			problems = append(problems, fmt.Errorf("%s: duplicate id %q", prefix, step.ID))
		} else {
			seen[step.ID] = struct{}{}
		}
		if strings.TrimSpace(step.Kind) == "" {
			problems = append(problems, fmt.Errorf("%s: kind is required", prefix))
		}
		if strings.TrimSpace(step.Description) == "" {
			problems = append(problems, fmt.Errorf("%s: description is required", prefix))
		}
	}
	return errors.Join(problems...)
}

// WriteJSON writes a stable, human-readable representation.
func (p Plan) WriteJSON(w io.Writer) error {
	if err := p.Validate(); err != nil {
		return err
	}
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	encoder.SetEscapeHTML(false)
	return encoder.Encode(p)
}

// Kinds returns the ordered set of kinds represented in the plan.
func (p Plan) Kinds() []string {
	var kinds []string
	for _, step := range p.Steps {
		if !slices.Contains(kinds, step.Kind) {
			kinds = append(kinds, step.Kind)
		}
	}
	return kinds
}

func cloneStep(step Step) Step {
	clone := step
	if step.Inputs != nil {
		clone.Inputs = make(map[string]string, len(step.Inputs))
		for key, value := range step.Inputs {
			clone.Inputs[key] = value
		}
	}
	return clone
}
