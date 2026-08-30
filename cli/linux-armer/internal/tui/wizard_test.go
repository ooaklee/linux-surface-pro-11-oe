package tui

import (
	"io"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/catalog"
)

func TestModelNavigation(t *testing.T) {
	entries := testEntries()
	tests := []struct {
		name       string
		cursor     int
		key        tea.KeyPressMsg
		wantCursor int
	}{
		{name: "up stops at first entry", cursor: 0, key: specialKey(tea.KeyUp), wantCursor: 0},
		{name: "k stops at first entry", cursor: 0, key: textKey('k'), wantCursor: 0},
		{name: "down moves to next entry", cursor: 0, key: specialKey(tea.KeyDown), wantCursor: 1},
		{name: "j moves to next entry", cursor: 0, key: textKey('j'), wantCursor: 1},
		{name: "down stops at last entry", cursor: len(entries) - 1, key: specialKey(tea.KeyDown), wantCursor: len(entries) - 1},
		{name: "j stops at last entry", cursor: len(entries) - 1, key: textKey('j'), wantCursor: len(entries) - 1},
		{name: "up moves to previous entry", cursor: len(entries) - 1, key: specialKey(tea.KeyUp), wantCursor: len(entries) - 2},
		{name: "k moves to previous entry", cursor: len(entries) - 1, key: textKey('k'), wantCursor: len(entries) - 2},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			initial := model{entries: entries, cursor: tt.cursor, output: "image.raw"}
			updated, cmd := updateModel(t, initial, tt.key)

			if cmd != nil {
				t.Fatal("navigation returned a command; want nil")
			}
			if updated.cursor != tt.wantCursor {
				t.Fatalf("cursor = %d, want %d", updated.cursor, tt.wantCursor)
			}
		})
	}
}

func TestModelCatalogOnlyEntryShowsMessage(t *testing.T) {
	entries := testEntries()
	initial := model{entries: entries, output: "image.raw"}

	updated, cmd := updateModel(t, initial, specialKey(tea.KeyEnter))
	if cmd != nil {
		t.Fatal("catalog-only selection returned a command; want nil")
	}
	if updated.confirm {
		t.Fatal("confirm = true for a catalog-only entry; want false")
	}
	if updated.selected {
		t.Fatal("selected = true for a catalog-only entry; want false")
	}
	wantMessage := "Catalog One is catalog-only; its image adapter is not implemented yet."
	if updated.message != wantMessage {
		t.Fatalf("message = %q, want %q", updated.message, wantMessage)
	}

	view := updated.View()
	if !view.AltScreen {
		t.Fatal("View().AltScreen = false, want true")
	}
	for _, text := range []string{
		"Choose an ARM64 source image:",
		"Catalog One  [catalog-only]",
		wantMessage,
		"enter select · q quit",
	} {
		if !strings.Contains(view.Content, text) {
			t.Errorf("view does not contain %q\nview:\n%s", text, view.Content)
		}
	}
}

func TestModelImplementedEntryOpensConfirmation(t *testing.T) {
	entries := testEntries()
	initial := model{
		entries: entries,
		cursor:  1,
		output:  "/tmp/linux-armer.img",
		message: "old warning",
	}

	updated, cmd := updateModel(t, initial, specialKey(tea.KeyEnter))
	if cmd != nil {
		t.Fatal("implemented selection returned a command; want nil")
	}
	if !updated.confirm {
		t.Fatal("confirm = false for an implemented entry; want true")
	}
	if updated.selected {
		t.Fatal("selected = true before confirmation; want false")
	}
	if updated.message != "" {
		t.Fatalf("message = %q, want empty", updated.message)
	}

	view := updated.View()
	if !view.AltScreen {
		t.Fatal("View().AltScreen = false, want true")
	}
	for _, text := range []string{
		"Ready to create an experimental image:",
		"Ubuntu Concept",
		"kernel: latest complete linux-armer release",
		"output: /tmp/linux-armer.img",
		"Secure Boot must be disabled.",
		"enter/b build · esc back · q quit",
	} {
		if !strings.Contains(view.Content, text) {
			t.Errorf("confirmation view does not contain %q\nview:\n%s", text, view.Content)
		}
	}
	if strings.Contains(view.Content, "Choose an ARM64 source image:") {
		t.Errorf("confirmation view unexpectedly contains selection prompt\nview:\n%s", view.Content)
	}
}

func TestModelConfirmationBackKeys(t *testing.T) {
	for _, tt := range []struct {
		name string
		key  tea.KeyPressMsg
	}{
		{name: "escape", key: specialKey(tea.KeyEsc)},
		{name: "backspace", key: specialKey(tea.KeyBackspace)},
	} {
		t.Run(tt.name, func(t *testing.T) {
			initial := model{
				entries: testEntries(),
				cursor:  1,
				confirm: true,
				output:  "image.raw",
				message: "old warning",
			}

			updated, cmd := updateModel(t, initial, tt.key)
			if cmd != nil {
				t.Fatal("back key returned a command; want nil")
			}
			if updated.confirm {
				t.Fatal("confirm = true after back key; want false")
			}
			if updated.selected {
				t.Fatal("selected = true after back key; want false")
			}
			if updated.cursor != initial.cursor {
				t.Fatalf("cursor = %d, want %d", updated.cursor, initial.cursor)
			}
			if updated.message != "" {
				t.Fatalf("message = %q, want empty", updated.message)
			}
			if content := updated.View().Content; !strings.Contains(content, "Choose an ARM64 source image:") {
				t.Errorf("view does not return to selection prompt\nview:\n%s", content)
			}
		})
	}
}

func TestModelConfirmationBuildKeysSelectAndQuit(t *testing.T) {
	for _, tt := range []struct {
		name string
		key  tea.KeyPressMsg
	}{
		{name: "enter", key: specialKey(tea.KeyEnter)},
		{name: "b", key: textKey('b')},
	} {
		t.Run(tt.name, func(t *testing.T) {
			initial := model{entries: testEntries(), cursor: 1, confirm: true, output: "image.raw"}

			updated, cmd := updateModel(t, initial, tt.key)
			if !updated.selected {
				t.Fatal("selected = false after build confirmation; want true")
			}
			if updated.cursor != initial.cursor {
				t.Fatalf("cursor = %d, want %d", updated.cursor, initial.cursor)
			}
			assertQuitCommand(t, cmd)
		})
	}
}

func TestModelQuitKeys(t *testing.T) {
	keys := []struct {
		name string
		key  tea.KeyPressMsg
	}{
		{name: "q", key: textKey('q')},
		{name: "ctrl-c", key: tea.KeyPressMsg(tea.Key{Code: 'c', Mod: tea.ModCtrl})},
	}
	for _, confirm := range []bool{false, true} {
		mode := "selection"
		if confirm {
			mode = "confirmation"
		}
		for _, tt := range keys {
			t.Run(mode+"/"+tt.name, func(t *testing.T) {
				initial := model{entries: testEntries(), cursor: 1, confirm: confirm, output: "image.raw"}

				updated, cmd := updateModel(t, initial, tt.key)
				if updated.selected {
					t.Fatal("selected = true after quit key; want false")
				}
				if updated.confirm != initial.confirm {
					t.Fatalf("confirm = %t, want %t", updated.confirm, initial.confirm)
				}
				assertQuitCommand(t, cmd)
			})
		}
	}
}

func TestModelWindowSize(t *testing.T) {
	initial := model{entries: testEntries(), width: 20}

	updated, cmd := updateModel(t, initial, tea.WindowSizeMsg{Width: 120, Height: 40})
	if cmd != nil {
		t.Fatal("window size update returned a command; want nil")
	}
	if updated.width != 120 {
		t.Fatalf("width = %d, want 120", updated.width)
	}
}

func TestRunRejectsEmptyCatalog(t *testing.T) {
	selection, selected, err := Run(nil, "image.raw", strings.NewReader(""), io.Discard)
	if err == nil {
		t.Fatal("Run() error = nil, want empty catalog error")
	}
	if got, want := err.Error(), "supported image catalog is empty"; got != want {
		t.Fatalf("Run() error = %q, want %q", got, want)
	}
	if selected {
		t.Fatal("Run() selected = true, want false")
	}
	if selection != (Selection{}) {
		t.Fatalf("Run() selection = %#v, want zero value", selection)
	}
}

func testEntries() []catalog.Entry {
	return []catalog.Entry{
		{ID: "catalog-one", Name: "Catalog One", SupportLevel: catalog.SupportLevelCatalogOnly},
		{ID: "ubuntu-concept", Name: "Ubuntu Concept", SupportLevel: catalog.SupportLevelImplemented},
		{ID: "catalog-two", Name: "Catalog Two", SupportLevel: catalog.SupportLevelCatalogOnly},
	}
}

func textKey(code rune) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Code: code, Text: string(code)})
}

func specialKey(code rune) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Code: code})
}

func updateModel(t *testing.T, initial model, message tea.Msg) (model, tea.Cmd) {
	t.Helper()

	next, cmd := initial.Update(message)
	updated, ok := next.(model)
	if !ok {
		t.Fatalf("Update() model type = %T, want tui.model", next)
	}
	return updated, cmd
}

func assertQuitCommand(t *testing.T, cmd tea.Cmd) {
	t.Helper()

	if cmd == nil {
		t.Fatal("command = nil, want tea.Quit")
	}
	if message := cmd(); message != (tea.QuitMsg{}) {
		t.Fatalf("command message = %#v, want tea.QuitMsg", message)
	}
}
