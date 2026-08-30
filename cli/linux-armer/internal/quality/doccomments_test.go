// Package quality contains repository-wide source quality gates.
package quality

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// TestDeclarationsHaveDocComments keeps the complete Go codebase understandable
// by requiring plain documentation on every named function, method, type,
// variable group, and constant group, including test helpers.
func TestDeclarationsHaveDocComments(t *testing.T) {
	moduleRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	var missing []string
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
		if !strings.HasSuffix(path, ".go") {
			return nil
		}
		parsed, err := parser.ParseFile(fileSet, path, nil, parser.ParseComments)
		if err != nil {
			return err
		}
		for _, declaration := range parsed.Decls {
			switch item := declaration.(type) {
			case *ast.FuncDecl:
				if item.Doc == nil {
					missing = append(missing, sourceLabel(moduleRoot, fileSet, item.Pos(), "function "+item.Name.Name))
				}
			case *ast.GenDecl:
				if item.Tok == token.IMPORT {
					continue
				}
				for _, specification := range item.Specs {
					typeSpec, isType := specification.(*ast.TypeSpec)
					valueSpec, isValue := specification.(*ast.ValueSpec)
					documented := item.Doc != nil ||
						(isType && (typeSpec.Doc != nil || typeSpec.Comment != nil)) ||
						(isValue && (valueSpec.Doc != nil || valueSpec.Comment != nil))
					if !documented {
						label := strings.ToLower(item.Tok.String()) + " declaration"
						if isType {
							label = "type " + typeSpec.Name.Name

						}
						if isValue && len(valueSpec.Names) != 0 {
							names := make([]string, 0, len(valueSpec.Names))
							for _, name := range valueSpec.Names {
								names = append(names, name.Name)
							}
							label = strings.ToLower(item.Tok.String()) + " " + strings.Join(names, ", ")
						}
						missing = append(missing, sourceLabel(moduleRoot, fileSet, specification.Pos(), label))
					}
					if !isType {
						continue
					}
					interfaceType, ok := typeSpec.Type.(*ast.InterfaceType)
					if !ok {
						continue
					}
					for _, method := range interfaceType.Methods.List {
						if len(method.Names) == 0 || method.Doc != nil || method.Comment != nil {
							continue
						}
						missing = append(missing, sourceLabel(moduleRoot, fileSet, method.Pos(), "interface method "+method.Names[0].Name))
					}
				}
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(missing) != 0 {
		sort.Strings(missing)
		t.Fatalf("Go declarations without human-readable doc comments:\n%s", strings.Join(missing, "\n"))
	}
}

// sourceLabel formats one missing declaration with a portable module-relative
// source location so the failure can be fixed directly.
func sourceLabel(moduleRoot string, fileSet *token.FileSet, position token.Pos, declaration string) string {
	location := fileSet.Position(position)
	relative, err := filepath.Rel(moduleRoot, location.Filename)
	if err != nil {
		relative = location.Filename
	}
	return fmt.Sprintf("%s:%d: %s", filepath.ToSlash(relative), location.Line, declaration)
}
