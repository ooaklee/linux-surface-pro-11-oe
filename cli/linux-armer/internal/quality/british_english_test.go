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
var americanEnglishPattern = regexp.MustCompile(`(?i)\b(?:artifacts?|behaviors?|behavioral|canonicaliz(?:e|es|ed|ing|ation)|containeriz(?:e|es|ed|ing|ation)|dockeriz(?:e|es|ed|ing|ation)|generaliz(?:e|es|ed|ing|ation)|neutraliz(?:e|es|ed|ing|ation)|prioritiz(?:e|es|ed|ing|ation)|randomiz(?:e|es|ed|ing|ation)|stabiliz(?:e|es|ed|ing|ation)|synthesiz(?:e|es|ed|ing|ation)|normaliz(?:e|es|ed|ing|ation)|recogniz(?:e|es|ed|ing)|unrecognized|initializ(?:e|es|ed|ing|ation)|uninitializ(?:e|es|ed|ing)|authoriz(?:e|es|ed|ing|ation)|serializ(?:e|es|ed|ing|ation|able)|organiz(?:e|es|ed|ing|ation)|colors?|colored|licenses?|defenses?|centers?|centered|centering|analyz(?:e|es|ed|ing)|optimiz(?:e|es|ed|ing|ation)|customiz(?:e|es|ed|ing)|canceled|canceling|labeled|labeling|modeled|modeling|materializ(?:e|es|ed|ing)|summariz(?:e|es|ed|ing)|sanitiz(?:e|es|ed|ing)|unsanitiz(?:e|es|ed|ing)|favors?|favored|honors?|honored|honoring)\b`)

// markdownURLPattern removes link destinations because their spellings belong
// to external resource identifiers rather than editable project prose.
var markdownURLPattern = regexp.MustCompile(`https?://[^\s)>]+`)

// markdownLinkDestinationPattern removes local link targets because filenames
// and stable slugs are identifiers rather than editable project prose.
var markdownLinkDestinationPattern = regexp.MustCompile(`\]\([^)]*\)`)

// TestDocumentationUsesBritishEnglish scans CLI Go comments and repository-wide
// public Markdown or JSON prose so future changes preserve the project's chosen
// language style.
func TestDocumentationUsesBritishEnglish(t *testing.T) {
	repositoryRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	var issues []string
	fileSet := token.NewFileSet()
	err = filepath.WalkDir(repositoryRoot, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			if entry.Name() == ".git" || path == filepath.Join(repositoryRoot, "build") || path == filepath.Join(repositoryRoot, "bin") {
				return filepath.SkipDir
			}
			return nil
		}
		switch filepath.Ext(path) {
		case ".go":
			if !strings.HasPrefix(path, filepath.Join(repositoryRoot, "cli", "linux-armer")+string(filepath.Separator)) {
				return nil
			}
			parsed, err := parser.ParseFile(fileSet, path, nil, parser.ParseComments)
			if err != nil {
				return err
			}
			for _, group := range parsed.Comments {
				for _, comment := range group.List {
					text := strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(comment.Text, "//"), "/*"))
					// Stable Go identifiers must begin their documentation with their
					// exact source spelling even when the public prose uses another form.
					for _, identifier := range []string{"Artifact", "Artifacts", "Recognized", "artifact", "artifacts"} {
						text = strings.TrimPrefix(text, identifier+" ")
					}
					text = strings.TrimPrefix(text, "Package artifact ")
					if spelling := americanEnglishPattern.FindString(text); spelling != "" {
						position := fileSet.Position(comment.Pos())
						relative, _ := filepath.Rel(repositoryRoot, path)
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
				if filepath.Ext(path) == ".md" && strings.HasPrefix(strings.TrimSpace(line), "id:") {
					continue
				}
				if filepath.Ext(path) == ".md" && strings.HasPrefix(strings.TrimSpace(line), "```") {
					inFence = !inFence
					continue
				}
				if inFence {
					continue
				}
				prose := line
				if filepath.Ext(path) == ".md" {
					prose = markdownProse(line)
				}
				if spelling := americanEnglishPattern.FindString(prose); spelling != "" {
					relative, _ := filepath.Rel(repositoryRoot, path)
					issues = append(issues, fmt.Sprintf("%s:%d: replace %q with British English", filepath.ToSlash(relative), lineNumber, spelling))
				}
			}
			scanErr := scanner.Err()
			closeErr := file.Close()
			if scanErr != nil || closeErr != nil {
				return fmt.Errorf("scan British-English documentation %s: %w", path, errors.Join(scanErr, closeErr))
			}
		case ".ps1":
			if !strings.HasPrefix(path, filepath.Join(repositoryRoot, "cli", "linux-armer")+string(filepath.Separator)) {
				return nil
			}
			content, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			for _, comment := range powerShellCommentLines(string(content)) {
				if spelling := americanEnglishPattern.FindString(comment.text); spelling != "" {
					relative, _ := filepath.Rel(repositoryRoot, path)
					issues = append(issues, fmt.Sprintf("%s:%d: replace %q with British English", filepath.ToSlash(relative), comment.line, spelling))
				}
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

// powerShellComment is one comment fragment and its one-based source line.
type powerShellComment struct {
	// line is the one-based source line containing the comment.
	line int
	// text is the editable comment prose without comment delimiters.
	text string
}

// powerShellCommentLines extracts PowerShell block and line comments plus
// embedded C# XML summaries while leaving identifiers and string values alone.
func powerShellCommentLines(content string) []powerShellComment {
	comments := make([]powerShellComment, 0)
	inBlock := false
	for index, line := range strings.Split(content, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.Contains(trimmed, "<#") {
			inBlock = true
			trimmed = strings.TrimSpace(strings.SplitN(trimmed, "<#", 2)[1])
		}
		if inBlock {
			if end := strings.Index(trimmed, "#>"); end >= 0 {
				trimmed = trimmed[:end]
				inBlock = false
			}
			comments = append(comments, powerShellComment{line: index + 1, text: trimmed})
			continue
		}
		if strings.HasPrefix(trimmed, "///") {
			comments = append(comments, powerShellComment{line: index + 1, text: strings.TrimSpace(strings.TrimPrefix(trimmed, "///"))})
			continue
		}
		if strings.HasPrefix(trimmed, "#") && !strings.HasPrefix(trimmed, "#requires") {
			comments = append(comments, powerShellComment{line: index + 1, text: strings.TrimSpace(strings.TrimPrefix(trimmed, "#"))})
		}
	}
	return comments
}

// markdownProse removes inline code spans so stable identifiers and preserved
// command names are not mistaken for editable public prose.
func markdownProse(line string) string {
	line = markdownURLPattern.ReplaceAllString(line, " ")
	line = markdownLinkDestinationPattern.ReplaceAllString(line, "]")
	var prose strings.Builder
	inCode := false
	delimiterLength := 0
	for index := 0; index < len(line); {
		if line[index] != '`' {
			if !inCode {
				prose.WriteByte(line[index])
			}
			index++
			continue
		}
		runEnd := index + 1
		for runEnd < len(line) && line[runEnd] == '`' {
			runEnd++
		}
		runLength := runEnd - index
		if !inCode {
			inCode = true
			delimiterLength = runLength
		} else if runLength == delimiterLength {
			inCode = false
			delimiterLength = 0
			prose.WriteByte(' ')
		}
		index = runEnd
	}
	return prose.String()
}

// TestMarkdownProseExcludesIdentifiersAndURLs verifies the prose scanner keeps
// editable words while ignoring stable inline code and external destinations.
func TestMarkdownProseExcludesIdentifiersAndURLs(t *testing.T) {
	input := "Review behavior beside `API behavior`, [an artefact](release-artifacts.md), and <https://example.org/behavior>."
	got := markdownProse(input)
	if strings.Count(got, "behavior") != 1 {
		t.Fatalf("markdownProse() retained %q, want only the editable prose occurrence", got)
	}
	if strings.Contains(got, "release-artifacts") {
		t.Fatalf("markdownProse() retained local link destination in %q", got)
	}
}
