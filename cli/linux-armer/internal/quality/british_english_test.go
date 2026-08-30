package quality

import (
	"bufio"
	"errors"
	"fmt"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// americanEnglishPattern identifies unambiguous American spellings for which
// this project has selected a British equivalent in public prose.
var americanEnglishPattern = regexp.MustCompile(`(?i)\b(?:behaviors?|behavioral|normaliz(?:e|es|ed|ing|ation)|recogniz(?:e|es|ed|ing)|unrecognized|initializ(?:e|es|ed|ing|ation)|authoriz(?:e|es|ed|ing|ation)|serializ(?:e|es|ed|ing|ation|able)|organiz(?:e|es|ed|ing|ation)|colors?|colored|licenses?|licensed|licensing|defenses?|centers?|centered|centering|analyz(?:e|es|ed|ing)|optimiz(?:e|es|ed|ing|ation)|customiz(?:e|es|ed|ing)|canceled|canceling|labeled|labeling|modeled|modeling|materializ(?:e|es|ed|ing)|summariz(?:e|es|ed|ing)|sanitiz(?:e|es|ed|ing)|favors?|favored|honors?|honored|honoring)\b`)

// TestDocumentationUsesBritishEnglish scans Go comments and public Markdown or
// JSON prose so future changes preserve the project's chosen language style.
func TestDocumentationUsesBritishEnglish(t *testing.T) {
	moduleRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	var issues []string
	fileSet := token.NewFileSet()
	err = filepath.WalkDir(moduleRoot, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			if entry.Name() == ".git" || path == filepath.Join(moduleRoot, "build") || path == filepath.Join(moduleRoot, "bin") {
				return filepath.SkipDir
			}
			return nil
		}
		switch filepath.Ext(path) {
		case ".go":
			parsed, err := parser.ParseFile(fileSet, path, nil, parser.ParseComments)
			if err != nil {
				return err
			}
			for _, group := range parsed.Comments {
				for _, comment := range group.List {
					text := strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(comment.Text, "//"), "/*"))
					// Recognized is a stable exported JSON field and must begin its
					// Go documentation with the exact identifier spelling.
					text = strings.TrimPrefix(text, "Recognized ")
					if spelling := americanEnglishPattern.FindString(text); spelling != "" {
						position := fileSet.Position(comment.Pos())
						relative, _ := filepath.Rel(moduleRoot, path)
						issues = append(issues, fmt.Sprintf("%s:%d: replace %q with British English", filepath.ToSlash(relative), position.Line, spelling))
					}
				}
			}
		case ".md", ".json":
			file, err := os.Open(path)
			if err != nil {
				return err
			}
			scanner := bufio.NewScanner(file)
			lineNumber := 0
			inFence := false
			for scanner.Scan() {
				lineNumber++
				line := scanner.Text()
				if filepath.Ext(path) == ".md" && strings.HasPrefix(strings.TrimSpace(line), "```") {
					inFence = !inFence
					continue
				}
				if inFence {
					continue
				}
				if spelling := americanEnglishPattern.FindString(line); spelling != "" {
					relative, _ := filepath.Rel(moduleRoot, path)
					issues = append(issues, fmt.Sprintf("%s:%d: replace %q with British English", filepath.ToSlash(relative), lineNumber, spelling))
				}
			}
			scanErr := scanner.Err()
			closeErr := file.Close()
			if scanErr != nil || closeErr != nil {
				return fmt.Errorf("scan British-English documentation %s: %w", path, errors.Join(scanErr, closeErr))
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(issues) != 0 {
		sort.Strings(issues)
		t.Fatalf("American spellings found in documentation:\n%s", strings.Join(issues, "\n"))
	}
}
