package quality

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

var (
	// powerShellFunctionPattern identifies named PowerShell function definitions
	// without mistaking prose beginning with the word function for code.
	powerShellFunctionPattern = regexp.MustCompile(`^\s*function\s+(?:global:)?([A-Za-z][A-Za-z0-9_-]*)\s*\{`)
	// embeddedCSharpTypePattern identifies the named classes and structs carried
	// by the collector's Windows API boundary.
	embeddedCSharpTypePattern = regexp.MustCompile(`^\s*(?:public|private|protected|internal)\s+(?:sealed\s+|static\s+)?(?:class|struct)\s+([A-Za-z_][A-Za-z0-9_]*)`)
	// embeddedCSharpMethodPattern identifies constructors and methods in the
	// collector's embedded C# without matching fields or properties.
	embeddedCSharpMethodPattern = regexp.MustCompile(`^\s*(?:public|private|protected|internal)\s+(?:static\s+)?(?:extern\s+)?(?:[A-Za-z0-9_.<>\[\]]+\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(`)
)

// TestPowerShellDeclarationsHaveDocComments keeps every PowerShell function and
// embedded C# type or method understandable through adjacent human prose.
func TestPowerShellDeclarationsHaveDocComments(t *testing.T) {
	moduleRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	var missing []string
	err = filepath.WalkDir(moduleRoot, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || filepath.Ext(path) != ".ps1" {
			return nil
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		lines := strings.Split(string(content), "\n")
		for index, line := range lines {
			if match := powerShellFunctionPattern.FindStringSubmatch(line); match != nil {
				if !hasPowerShellDocComment(lines, index) {
					missing = append(missing, declarationLocation(moduleRoot, path, index+1, "PowerShell function "+match[1]))
				}
			}
			if match := embeddedCSharpTypePattern.FindStringSubmatch(line); match != nil {
				if !hasCSharpSummary(lines, index) {
					missing = append(missing, declarationLocation(moduleRoot, path, index+1, "embedded C# type "+match[1]))
				}
				continue
			}
			if match := embeddedCSharpMethodPattern.FindStringSubmatch(line); match != nil && !hasCSharpSummary(lines, index) {
				missing = append(missing, declarationLocation(moduleRoot, path, index+1, "embedded C# method "+match[1]))
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(missing) != 0 {
		sort.Strings(missing)
		t.Fatalf("PowerShell or embedded C# declarations without human-readable doc comments:\n%s", strings.Join(missing, "\n"))
	}
}

// hasPowerShellDocComment reports whether the nearest preceding non-empty text
// is a block or line comment containing several words of explanation.
func hasPowerShellDocComment(lines []string, declarationIndex int) bool {
	index := previousNonEmptyLine(lines, declarationIndex-1)
	if index < 0 {
		return false
	}
	trimmed := strings.TrimSpace(lines[index])
	if strings.HasPrefix(trimmed, "#") && !strings.HasPrefix(trimmed, "#>") {
		return humanReadableComment(trimmed)
	}
	if !strings.Contains(trimmed, "#>") {
		return false
	}
	var comment []string
	for ; index >= 0; index-- {
		comment = append(comment, lines[index])
		if strings.Contains(lines[index], "<#") {
			return humanReadableComment(strings.Join(comment, " "))
		}
	}
	return false
}

// hasCSharpSummary reports whether a C# declaration has an adjacent XML
// summary, allowing framework attributes between the summary and declaration.
func hasCSharpSummary(lines []string, declarationIndex int) bool {
	index := previousNonEmptyLine(lines, declarationIndex-1)
	for index >= 0 && strings.HasPrefix(strings.TrimSpace(lines[index]), "[") {
		index = previousNonEmptyLine(lines, index-1)
	}
	if index < 0 {
		return false
	}
	trimmed := strings.TrimSpace(lines[index])
	return strings.HasPrefix(trimmed, "/// <summary>") && humanReadableComment(trimmed)
}

// previousNonEmptyLine returns the nearest prior line containing non-space
// text, or -1 when no such line exists.
func previousNonEmptyLine(lines []string, index int) int {
	for ; index >= 0; index-- {
		if strings.TrimSpace(lines[index]) != "" {
			return index
		}
	}
	return -1
}

// humanReadableComment requires at least four prose-like words after removing
// comment punctuation and PowerShell help field names.
func humanReadableComment(comment string) bool {
	replacer := strings.NewReplacer("<#", " ", "#>", " ", "///", " ", "//", " ", "#", " ", "<summary>", " ", "</summary>", " ")
	words := strings.Fields(replacer.Replace(comment))
	return len(words) >= 4
}

// declarationLocation formats a portable source location for a missing
// PowerShell or embedded C# declaration comment.
func declarationLocation(moduleRoot, path string, line int, declaration string) string {
	relative, err := filepath.Rel(moduleRoot, path)
	if err != nil {
		relative = path
	}
	return fmt.Sprintf("%s:%d: %s", filepath.ToSlash(relative), line, declaration)
}
