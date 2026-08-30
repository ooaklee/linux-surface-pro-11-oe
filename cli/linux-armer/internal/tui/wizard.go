// Package tui provides the interactive delivery layer for linux-armer.
package tui

import (
	"fmt"
	"io"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/catalog"
)

// Selection is the minimal, validated intent returned when an operator confirms
// an image build in the interactive wizard.
type Selection struct {
	// CatalogID identifies the chosen supported-image entry.
	CatalogID string
	// Output is the destination supplied when the wizard was started.
	Output string
}

// model contains the wizard's immutable catalogue input and transient Bubble Tea
// navigation state.
type model struct {
	// entries is a private copy of the catalogue choices displayed to the operator.
	entries []catalog.Entry
	// cursor is the zero-based index of the currently highlighted entry.
	cursor int
	// width tracks terminal width for future responsive rendering.
	width int
	// confirm switches the view from selection to the final safety prompt.
	confirm bool
	// selected distinguishes a confirmed build from a normal quit.
	selected bool
	// output is the destination included in the confirmed Selection.
	output string
	// kernelSource describes the caller-selected kernel input without claiming
	// it has already passed the later integrity checks.
	kernelSource string
	// message explains why the current catalogue entry cannot be built.
	message string
}

// Wizard styles keep selection, secondary text, and safety warnings visually
// distinct without carrying any interaction state.
var (
	titleStyle    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#FFD75F"))
	selectedStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#7DD3FC"))
	dimStyle      = lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8"))
	warnStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("#FCA5A5"))
)

// Run starts the interactive image picker and returns a selection only after an
// implemented catalogue entry passes the explicit confirmation screen.
func Run(entries []catalog.Entry, output, kernelSource string, input io.Reader, writer io.Writer) (Selection, bool, error) {
	if len(entries) == 0 {
		return Selection{}, false, fmt.Errorf("supported image catalog is empty")
	}
	initial := model{
		entries:      append([]catalog.Entry(nil), entries...),
		output:       output,
		kernelSource: kernelSource,
	}
	options := []tea.ProgramOption{tea.WithInput(input), tea.WithOutput(writer)}
	final, err := tea.NewProgram(initial, options...).Run()
	if err != nil {
		return Selection{}, false, err
	}
	completed, ok := final.(model)
	if !ok || !completed.selected {
		return Selection{}, false, nil
	}
	return Selection{CatalogID: completed.entries[completed.cursor].ID, Output: completed.output}, true, nil
}

// Init declares that the wizard has no asynchronous startup command.
func (model) Init() tea.Cmd { return nil }

// Update applies terminal-size and key events, enforcing that catalogue-only
// entries cannot reach the confirmed-build state.
func (m model) Update(message tea.Msg) (tea.Model, tea.Cmd) {
	switch message := message.(type) {
	case tea.WindowSizeMsg:
		m.width = message.Width
	case tea.KeyPressMsg:
		key := message.String()
		if key == "ctrl+c" || key == "q" {
			return m, tea.Quit
		}
		if m.confirm {
			switch key {
			case "esc", "backspace":
				m.confirm = false
				m.message = ""
			case "enter", "b":
				m.selected = true
				return m, tea.Quit
			}
			return m, nil
		}
		switch key {
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "j":
			if m.cursor < len(m.entries)-1 {
				m.cursor++
			}
		case "enter":
			entry := m.entries[m.cursor]
			if entry.SupportLevel != catalog.SupportLevelImplemented {
				m.message = entry.Name + " is catalog-only; its image adapter is not implemented yet."
			} else {
				m.confirm = true
				m.message = ""
			}
		}
	}
	return m, nil
}

// View renders either the catalogue picker or the final build warning as a Bubble
// Tea alternate-screen view.
func (m model) View() tea.View {
	var body strings.Builder
	body.WriteString(titleStyle.Render("linux-armer · Surface Pro 11 image wizard"))
	body.WriteString("\n\n")
	if m.confirm {
		entry := m.entries[m.cursor]
		body.WriteString("Ready to create an experimental image:\n\n")
		body.WriteString(selectedStyle.Render(entry.Name))
		body.WriteString("\n  kernel: ")
		body.WriteString(m.kernelSource)
		body.WriteString("\n  output: ")
		body.WriteString(m.output)
		body.WriteString("\n\n")
		body.WriteString(warnStyle.Render("Secure Boot must be disabled. Review the generated manifest before writing media."))
		body.WriteString("\n\n")
		body.WriteString(dimStyle.Render("enter/b build · esc back · q quit"))
	} else {
		body.WriteString("Choose an ARM64 source image:\n\n")
		for index, entry := range m.entries {
			cursor := "  "
			style := dimStyle
			if index == m.cursor {
				cursor = "› "
				style = selectedStyle
			}
			label := fmt.Sprintf("%s  [%s]", entry.Name, entry.SupportLevel)
			body.WriteString(cursor + style.Render(label) + "\n")
		}
		if m.message != "" {
			body.WriteString("\n" + warnStyle.Render(m.message) + "\n")
		}
		body.WriteString("\n" + dimStyle.Render("↑/↓ or j/k move · enter select · q quit"))
	}
	view := tea.NewView(body.String())
	view.AltScreen = true
	return view
}
