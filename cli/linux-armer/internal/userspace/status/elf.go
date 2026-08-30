package status

import (
	debugelf "debug/elf"
	"fmt"
	"io"
	"path/filepath"
	"sort"
	"strings"
	"unicode"
)

// maxInspectedELFBytes bounds every target executable, loader, and shared
// library before debug/elf parsing.
const maxInspectedELFBytes int64 = 64 << 20

// maxELFInterpreterBytes bounds the PT_INTERP string accepted from a target binary.
const maxELFInterpreterBytes = 4096

// maxELFRuntimeObjects bounds the transitive loader and DT_NEEDED closure.
const maxELFRuntimeObjects = 256

// maxELFDependencyDepth bounds recursive dependency traversal independently of
// cycle detection.
const maxELFDependencyDepth = 32

// iptsdELFBinaries are the two installed executables supplied by the pinned
// integration and assessed without running either one.
var iptsdELFBinaries = []string{
	"usr/local/libexec/sp11-iptsd",
	"usr/local/libexec/sp11-iptsd-check-device",
}

// standardAArch64LibraryDirectories cover the distribution locations used by
// the published ARM64 payload and its GNU runtime dependencies.
var standardAArch64LibraryDirectories = []string{
	"lib/aarch64-linux-gnu",
	"usr/lib/aarch64-linux-gnu",
	"lib64",
	"usr/lib64",
	"lib",
	"usr/lib",
}

// elfRuntimeInspector owns bounded state for one complete static dependency walk.
type elfRuntimeInspector struct {
	fs        *rootedFS
	visited   map[string]bool
	libraries map[string]bool
	issues    []string
	objects   int
}

// resolvedELFObject identifies one safely resolved target-root object before it
// is parsed. Its host path is used only within the quiescent-root trust boundary.
type resolvedELFObject struct {
	logicalPath string
	hostPath    string
	invalid     string
}

// inspectIPTSDELF validates the complete bounded AArch64 ELF interpreter and
// transitive DT_NEEDED closure for both installed pinned executables.
func inspectIPTSDELF(fs *rootedFS, required bool) (Check, error) {
	inspection := &elfRuntimeInspector{
		fs:        fs,
		visited:   make(map[string]bool),
		libraries: make(map[string]bool),
	}
	for _, logicalPath := range iptsdELFBinaries {
		if err := inspection.inspectObject(logicalPath, filepath.Base(logicalPath), true, 0); err != nil {
			return Check{}, err
		}
	}
	if len(inspection.issues) != 0 {
		sort.Strings(inspection.issues)
		return Check{
			ID:          "iptsd-elf-runtime",
			Feature:     FeatureIPTSD,
			State:       optionalState(required),
			Required:    required,
			Detail:      strings.Join(inspection.issues, "; "),
			Remediation: "install AArch64 versions of the reported loader and shared libraries inside the selected target root",
		}, nil
	}
	return Check{
		ID:       "iptsd-elf-runtime",
		Feature:  FeatureIPTSD,
		State:    StatePass,
		Required: required,
		Detail: fmt.Sprintf(
			"validated %d ELF64 little-endian AArch64 objects across both IPTSD executables and their transitive interpreter and DT_NEEDED closure: %s",
			inspection.objects, strings.Join(sortedKeys(inspection.libraries), ", "),
		),
	}, nil
}

// inspectObject validates one contained ELF object and recursively follows its
// interpreter and dynamic dependencies with cycle, depth, count, and size bounds.
func (inspection *elfRuntimeInspector) inspectObject(logicalPath, provenance string, requireInterpreter bool, depth int) error {
	if depth > maxELFDependencyDepth {
		inspection.issues = append(inspection.issues, provenance+fmt.Sprintf(": dependency depth exceeds %d", maxELFDependencyDepth))
		return nil
	}
	object, found, err := inspection.resolveObject(logicalPath)
	if err != nil {
		return err
	}
	if !found {
		inspection.issues = append(inspection.issues, provenance+": missing /"+filepath.ToSlash(strings.TrimLeft(logicalPath, "/")))
		return nil
	}
	if object.invalid != "" {
		inspection.issues = append(inspection.issues, provenance+": "+object.invalid)
		return nil
	}
	if inspection.visited[object.hostPath] {
		return nil
	}
	if inspection.objects >= maxELFRuntimeObjects {
		inspection.issues = append(inspection.issues, fmt.Sprintf("runtime dependency closure exceeds %d objects", maxELFRuntimeObjects))
		return nil
	}
	inspection.visited[object.hostPath] = true
	inspection.objects++

	file, err := debugelf.Open(object.hostPath)
	if err != nil {
		inspection.issues = append(inspection.issues, provenance+": not a readable ELF file ("+err.Error()+")")
		return nil
	}
	defer file.Close()
	if file.Class != debugelf.ELFCLASS64 || file.Data != debugelf.ELFDATA2LSB || file.Machine != debugelf.EM_AARCH64 {
		inspection.issues = append(inspection.issues, fmt.Sprintf(
			"%s: expected ELF64 little-endian AArch64, found %s %s %s",
			provenance, file.Class, file.Data, file.Machine,
		))
		return nil
	}

	if requireInterpreter {
		interpreter, interpreterIssues, err := inspectELFInterpreter(file)
		if err != nil {
			return fmt.Errorf("read target-root ELF interpreter for %s: %w", provenance, err)
		}
		for _, issue := range interpreterIssues {
			inspection.issues = append(inspection.issues, provenance+": "+issue)
		}
		if interpreter != "" && len(interpreterIssues) == 0 {
			loaderPath := strings.TrimLeft(filepath.Clean(interpreter), string(filepath.Separator))
			inspection.libraries[filepath.Base(loaderPath)] = true
			if err := inspection.inspectObject(loaderPath, provenance+" interpreter "+interpreter, false, depth+1); err != nil {
				return err
			}
		}
	}

	needed, err := elfNeededLibraries(file)
	if err != nil {
		inspection.issues = append(inspection.issues, provenance+": cannot read DT_NEEDED entries ("+err.Error()+")")
		return nil
	}
	searchDirectories, searchIssues := elfLibrarySearchDirectories(file, object.logicalPath)
	for _, issue := range searchIssues {
		inspection.issues = append(inspection.issues, provenance+": "+issue)
	}
	for _, library := range needed {
		inspection.libraries[library] = true
		if !safeELFLibraryName(library) {
			inspection.issues = append(inspection.issues, provenance+": unsafe DT_NEEDED entry "+fmt.Sprintf("%q", library))
			continue
		}
		dependencyPath, found, err := inspection.findLibrary(library, searchDirectories)
		if err != nil {
			return err
		}
		if !found {
			inspection.issues = append(inspection.issues, provenance+": missing shared library "+library)
			continue
		}
		if err := inspection.inspectObject(dependencyPath, provenance+" -> "+library, false, depth+1); err != nil {
			return err
		}
	}
	return nil
}

// resolveObject enforces target-root containment and the per-object size bound
// before an executable, loader, or shared library reaches debug/elf.
func (inspection *elfRuntimeInspector) resolveObject(logicalPath string) (resolvedELFObject, bool, error) {
	path, info, err := inspection.fs.regular(logicalPath, true)
	if missing(err) {
		return resolvedELFObject{}, false, nil
	}
	if err != nil {
		return resolvedELFObject{}, false, fmt.Errorf("inspect target-root ELF /%s: %w", filepath.ToSlash(strings.TrimLeft(logicalPath, "/")), err)
	}
	if info.Size() > maxInspectedELFBytes {
		return resolvedELFObject{
			logicalPath: strings.TrimLeft(logicalPath, "/"),
			invalid:     fmt.Sprintf("exceeds the %d-byte ELF inspection limit", maxInspectedELFBytes),
		}, true, nil
	}
	return resolvedELFObject{logicalPath: strings.TrimLeft(logicalPath, "/"), hostPath: path}, true, nil
}

// inspectELFInterpreter reads the bounded PT_INTERP payload and accepts one
// absolute, canonical target-root loader path.
func inspectELFInterpreter(file *debugelf.File) (string, []string, error) {
	interpreters := make([]string, 0, 1)
	for _, program := range file.Progs {
		if program.Type != debugelf.PT_INTERP {
			continue
		}
		if program.Filesz == 0 || program.Filesz > maxELFInterpreterBytes {
			return "", []string{"PT_INTERP has an invalid size"}, nil
		}
		data, err := io.ReadAll(io.LimitReader(program.Open(), maxELFInterpreterBytes+1))
		if err != nil {
			return "", nil, err
		}
		if len(data) > maxELFInterpreterBytes {
			return "", []string{"PT_INTERP exceeds the size limit"}, nil
		}
		interpreter := strings.TrimSuffix(string(data), "\x00")
		interpreters = append(interpreters, interpreter)
	}
	if len(interpreters) != 1 {
		return "", []string{fmt.Sprintf("expected one PT_INTERP entry, found %d", len(interpreters))}, nil
	}
	interpreter := interpreters[0]
	if !filepath.IsAbs(interpreter) || filepath.Clean(interpreter) != interpreter || strings.ContainsRune(interpreter, '\x00') {
		return "", []string{fmt.Sprintf("unsafe PT_INTERP path %q", interpreter)}, nil
	}
	return interpreter, nil, nil
}

// elfNeededLibraries returns a stable list of DT_NEEDED entries. An object with
// no dynamic section has no transitive dependencies rather than a parse error.
func elfNeededLibraries(file *debugelf.File) ([]string, error) {
	if file.SectionByType(debugelf.SHT_DYNAMIC) == nil {
		return nil, nil
	}
	needed, err := file.DynString(debugelf.DT_NEEDED)
	if err != nil {
		return nil, err
	}
	return uniqueSortedStrings(needed), nil
}

// elfLibrarySearchDirectories combines safe DT_RUNPATH or DT_RPATH entries
// with conventional AArch64 distribution directories while retaining lookup order.
func elfLibrarySearchDirectories(file *debugelf.File, binaryPath string) ([]string, []string) {
	dynamicPaths, err := file.DynString(debugelf.DT_RUNPATH)
	if err != nil || len(dynamicPaths) == 0 {
		dynamicPaths, _ = file.DynString(debugelf.DT_RPATH)
	}
	directories := make([]string, 0, len(standardAArch64LibraryDirectories)+len(dynamicPaths))
	issues := make([]string, 0)
	origin := filepath.Dir(binaryPath)
	for _, list := range dynamicPaths {
		for _, rawEntry := range strings.Split(list, ":") {
			entry := strings.TrimSpace(rawEntry)
			if entry == "" {
				continue
			}
			originRelative := strings.HasPrefix(entry, "$ORIGIN") || strings.HasPrefix(entry, "${ORIGIN}")
			entry = strings.ReplaceAll(entry, "${ORIGIN}", origin)
			entry = strings.ReplaceAll(entry, "$ORIGIN", origin)
			if strings.Contains(entry, "$") || (!filepath.IsAbs(rawEntry) && !originRelative) {
				issues = append(issues, fmt.Sprintf("unsupported dynamic-library search path %q", rawEntry))
				continue
			}
			clean, cleanErr := cleanRelative(entry)
			if cleanErr != nil {
				issues = append(issues, fmt.Sprintf("unsafe dynamic-library search path %q", rawEntry))
				continue
			}
			directories = append(directories, clean)
		}
	}
	directories = append(directories, standardAArch64LibraryDirectories...)
	return uniqueStringsInOrder(directories), issues
}

// findLibrary resolves a needed library beneath each safe target-root search
// directory and returns the first path in dynamic-loader lookup order.
func (inspection *elfRuntimeInspector) findLibrary(library string, directories []string) (string, bool, error) {
	for _, directory := range directories {
		logicalPath := filepath.Join(directory, library)
		_, found, err := inspection.resolveObject(logicalPath)
		if err != nil {
			return "", false, fmt.Errorf("resolve target-root ELF library %s in /%s: %w", library, filepath.ToSlash(directory), err)
		}
		if found {
			return logicalPath, true, nil
		}
	}
	return "", false, nil
}

// safeELFLibraryName accepts only a flat, printable DT_NEEDED filename,
// preventing a target object from directing inspection outside compiled paths.
func safeELFLibraryName(name string) bool {
	return name != "" && name == filepath.Base(name) && !strings.ContainsAny(name, `/\`) && name != "." && name != ".." &&
		!strings.ContainsFunc(name, func(character rune) bool { return unicode.IsControl(character) || unicode.IsSpace(character) })
}

// uniqueSortedStrings removes empty and duplicate strings before returning a
// stable lexical order for reports.
func uniqueSortedStrings(values []string) []string {
	unique := make(map[string]bool, len(values))
	for _, value := range values {
		if value != "" {
			unique[value] = true
		}
	}
	return sortedKeys(unique)
}

// uniqueStringsInOrder removes empty and duplicate strings while preserving
// the first occurrence required for loader search precedence.
func uniqueStringsInOrder(values []string) []string {
	seen := make(map[string]bool, len(values))
	unique := make([]string, 0, len(values))
	for _, value := range values {
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		unique = append(unique, value)
	}
	return unique
}
