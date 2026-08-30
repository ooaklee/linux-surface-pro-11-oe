package status

import (
	debugelf "debug/elf"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestInspectIPTSDELFResolvesStaticRuntime verifies AArch64 identity, PT_INTERP,
// and DT_NEEDED resolution using only synthetic target-root files.
func TestInspectIPTSDELFResolvesStaticRuntime(t *testing.T) {
	root := t.TempDir()
	loader := "/lib/ld-linux-aarch64.so.1"
	needed := []string{"libstdc++.so.6", "libm.so.6", "libgcc_s.so.1"}
	for _, binaryPath := range iptsdELFBinaries {
		writeSyntheticELF(t, root, binaryPath, debugelf.EM_AARCH64, loader, needed)
	}
	writeSyntheticELF(t, root, strings.TrimPrefix(loader, "/"), debugelf.EM_AARCH64, "", nil)
	for _, library := range needed {
		dependencies := []string(nil)
		if library == "libstdc++.so.6" {
			dependencies = []string{"libc.so.6"}
		}
		writeSyntheticELF(t, root, filepath.Join("usr/lib/aarch64-linux-gnu", library), debugelf.EM_AARCH64, "", dependencies)
	}
	writeSyntheticELF(t, root, "usr/lib/aarch64-linux-gnu/libc.so.6", debugelf.EM_AARCH64, "", []string{"libstdc++.so.6"})
	fs, err := newRootedFS(root)
	if err != nil {
		t.Fatal(err)
	}
	check, err := inspectIPTSDELF(fs, true)
	if err != nil {
		t.Fatal(err)
	}
	if check.State != StatePass || !strings.Contains(check.Detail, "libstdc++.so.6") || !strings.Contains(check.Detail, "libc.so.6") {
		t.Fatalf("ELF check = %#v", check)
	}
}

// TestInspectIPTSDELFRejectsWrongLoaderArchitecture verifies that PT_INTERP
// existence alone cannot satisfy readiness with a non-AArch64 loader.
func TestInspectIPTSDELFRejectsWrongLoaderArchitecture(t *testing.T) {
	root := t.TempDir()
	loader := "/lib/ld-linux-aarch64.so.1"
	for _, binaryPath := range iptsdELFBinaries {
		writeSyntheticELF(t, root, binaryPath, debugelf.EM_AARCH64, loader, nil)
	}
	writeSyntheticELF(t, root, strings.TrimPrefix(loader, "/"), debugelf.EM_X86_64, "", nil)
	fs, err := newRootedFS(root)
	if err != nil {
		t.Fatal(err)
	}
	check, err := inspectIPTSDELF(fs, true)
	if err != nil {
		t.Fatal(err)
	}
	if check.State != StateFail || !strings.Contains(check.Detail, "interpreter /lib/ld-linux-aarch64.so.1: expected ELF64 little-endian AArch64") {
		t.Fatalf("loader architecture check = %#v", check)
	}
}

// TestInspectIPTSDELFReportsArchitectureAndMissingLibraries verifies precise
// static diagnostics without loading or executing either target binary.
func TestInspectIPTSDELFReportsArchitectureAndMissingLibraries(t *testing.T) {
	root := t.TempDir()
	loader := "/lib/ld-linux-aarch64.so.1"
	needed := []string{"libstdc++.so.6", "libc.so.6"}
	writeSyntheticELF(t, root, iptsdELFBinaries[0], debugelf.EM_X86_64, loader, needed)
	writeSyntheticELF(t, root, iptsdELFBinaries[1], debugelf.EM_AARCH64, loader, needed)
	writeSyntheticELF(t, root, strings.TrimPrefix(loader, "/"), debugelf.EM_AARCH64, "", nil)
	writeSyntheticELF(t, root, "usr/lib/aarch64-linux-gnu/libc.so.6", debugelf.EM_AARCH64, "", nil)
	fs, err := newRootedFS(root)
	if err != nil {
		t.Fatal(err)
	}
	check, err := inspectIPTSDELF(fs, false)
	if err != nil {
		t.Fatal(err)
	}
	if check.State != StateWarn || check.Required {
		t.Fatalf("ELF check severity = %#v", check)
	}
	for _, expected := range []string{"expected ELF64 little-endian AArch64", "missing shared library libstdc++.so.6"} {
		if !strings.Contains(check.Detail, expected) {
			t.Fatalf("ELF detail %q does not contain %q", check.Detail, expected)
		}
	}
}

// TestInspectIPTSDELFRejectsEscapingLibraryLink verifies that dependency lookup
// never follows a target-root symbolic link onto the host filesystem.
func TestInspectIPTSDELFRejectsEscapingLibraryLink(t *testing.T) {
	root := t.TempDir()
	loader := "/lib/ld-linux-aarch64.so.1"
	for _, binaryPath := range iptsdELFBinaries {
		writeSyntheticELF(t, root, binaryPath, debugelf.EM_AARCH64, loader, []string{"libc.so.6"})
	}
	writeSyntheticELF(t, root, strings.TrimPrefix(loader, "/"), debugelf.EM_AARCH64, "", nil)
	libraryPath := filepath.Join(root, "usr/lib/aarch64-linux-gnu/libc.so.6")
	mkdir(t, filepath.Dir(libraryPath))
	if err := os.Symlink("../../../../../outside/libc.so.6", libraryPath); err != nil {
		t.Fatal(err)
	}
	fs, err := newRootedFS(root)
	if err != nil {
		t.Fatal(err)
	}
	_, err = inspectIPTSDELF(fs, true)
	if err == nil || !strings.Contains(err.Error(), "escapes root") {
		t.Fatalf("expected contained library resolution error, got %v", err)
	}
}

// TestInspectIPTSDELFRejectsNonELFTransitiveObject verifies that finding a
// dependency filename is insufficient unless the object itself is valid ARM64 ELF.
func TestInspectIPTSDELFRejectsNonELFTransitiveObject(t *testing.T) {
	root := t.TempDir()
	loader := "/lib/ld-linux-aarch64.so.1"
	for _, binaryPath := range iptsdELFBinaries {
		writeSyntheticELF(t, root, binaryPath, debugelf.EM_AARCH64, loader, []string{"libparent.so.1"})
	}
	writeSyntheticELF(t, root, strings.TrimPrefix(loader, "/"), debugelf.EM_AARCH64, "", nil)
	writeSyntheticELF(t, root, "usr/lib/aarch64-linux-gnu/libparent.so.1", debugelf.EM_AARCH64, "", []string{"libchild.so.1"})
	writeFile(t, root, "usr/lib/aarch64-linux-gnu/libchild.so.1", 0o644, "not an ELF object")
	fs, err := newRootedFS(root)
	if err != nil {
		t.Fatal(err)
	}
	check, err := inspectIPTSDELF(fs, true)
	if err != nil {
		t.Fatal(err)
	}
	if check.State != StateFail || !strings.Contains(check.Detail, "libchild.so.1: not a readable ELF file") {
		t.Fatalf("transitive ELF check = %#v", check)
	}
}

// writeSyntheticELF creates the smallest section-backed ELF64 file needed for
// debug/elf to expose PT_INTERP and DT_NEEDED entries in a portable unit test.
func writeSyntheticELF(t *testing.T, root, logicalPath string, machine debugelf.Machine, interpreter string, libraries []string) {
	t.Helper()
	interpreterBytes := append([]byte(interpreter), 0)
	dynamicStrings := []byte{0}
	stringOffsets := make([]uint64, 0, len(libraries))
	for _, library := range libraries {
		stringOffsets = append(stringOffsets, uint64(len(dynamicStrings)))
		dynamicStrings = append(dynamicStrings, []byte(library)...)
		dynamicStrings = append(dynamicStrings, 0)
	}
	sectionNames := []byte("\x00.dynamic\x00.dynstr\x00.shstrtab\x00")
	const (
		headerSize        = 64
		programHeaderSize = 56
		sectionHeaderSize = 64
		sectionCount      = 4
	)
	programCount := 1
	if interpreter != "" {
		programCount++
	}
	interpreterOffset := headerSize + programHeaderSize*programCount
	dynamicOffset := alignTestOffset(interpreterOffset+len(interpreterBytes), 8)
	dynamicSize := (len(libraries) + 1) * 16
	stringOffset := dynamicOffset + dynamicSize
	sectionNameOffset := stringOffset + len(dynamicStrings)
	sectionHeaderOffset := alignTestOffset(sectionNameOffset+len(sectionNames), 8)
	data := make([]byte, sectionHeaderOffset+sectionHeaderSize*sectionCount)
	copy(data[:16], []byte{0x7f, 'E', 'L', 'F', byte(debugelf.ELFCLASS64), byte(debugelf.ELFDATA2LSB), byte(debugelf.EV_CURRENT)})
	putTestUint16(data, 16, uint16(debugelf.ET_DYN))
	putTestUint16(data, 18, uint16(machine))
	putTestUint32(data, 20, uint32(debugelf.EV_CURRENT))
	putTestUint64(data, 32, headerSize)
	putTestUint64(data, 40, uint64(sectionHeaderOffset))
	putTestUint16(data, 52, headerSize)
	putTestUint16(data, 54, programHeaderSize)
	putTestUint16(data, 56, uint16(programCount))
	putTestUint16(data, 58, sectionHeaderSize)
	putTestUint16(data, 60, sectionCount)
	putTestUint16(data, 62, 3)

	dynamicProgramOffset := headerSize
	if interpreter != "" {
		writeTestProgramHeader(data, headerSize, debugelf.PT_INTERP, interpreterOffset, len(interpreterBytes), 1)
		dynamicProgramOffset += programHeaderSize
		copy(data[interpreterOffset:], interpreterBytes)
	}
	writeTestProgramHeader(data, dynamicProgramOffset, debugelf.PT_DYNAMIC, dynamicOffset, dynamicSize, 8)
	for index, offset := range stringOffsets {
		entry := dynamicOffset + index*16
		putTestUint64(data, entry, uint64(debugelf.DT_NEEDED))
		putTestUint64(data, entry+8, offset)
	}
	copy(data[stringOffset:], dynamicStrings)
	copy(data[sectionNameOffset:], sectionNames)

	writeTestSectionHeader(data, sectionHeaderOffset+sectionHeaderSize, 1, debugelf.SHT_DYNAMIC, dynamicOffset, dynamicSize, 2, 16)
	writeTestSectionHeader(data, sectionHeaderOffset+sectionHeaderSize*2, 10, debugelf.SHT_STRTAB, stringOffset, len(dynamicStrings), 0, 0)
	writeTestSectionHeader(data, sectionHeaderOffset+sectionHeaderSize*3, 18, debugelf.SHT_STRTAB, sectionNameOffset, len(sectionNames), 0, 0)
	path := filepath.Join(root, filepath.FromSlash(logicalPath))
	mkdir(t, filepath.Dir(path))
	if err := os.WriteFile(path, data, 0o755); err != nil {
		t.Fatal(err)
	}
}

// alignTestOffset rounds a fixture offset up to the requested power-of-two alignment.
func alignTestOffset(value, alignment int) int {
	return (value + alignment - 1) &^ (alignment - 1)
}

// putTestUint16 writes one little-endian ELF fixture field.
func putTestUint16(data []byte, offset int, value uint16) {
	binary.LittleEndian.PutUint16(data[offset:], value)
}

// putTestUint32 writes one little-endian ELF fixture field.
func putTestUint32(data []byte, offset int, value uint32) {
	binary.LittleEndian.PutUint32(data[offset:], value)
}

// putTestUint64 writes one little-endian ELF fixture field.
func putTestUint64(data []byte, offset int, value uint64) {
	binary.LittleEndian.PutUint64(data[offset:], value)
}

// writeTestProgramHeader writes one ELF64 program header for a fixture segment.
func writeTestProgramHeader(data []byte, offset int, kind debugelf.ProgType, fileOffset, size, alignment int) {
	putTestUint32(data, offset, uint32(kind))
	putTestUint32(data, offset+4, uint32(debugelf.PF_R))
	putTestUint64(data, offset+8, uint64(fileOffset))
	putTestUint64(data, offset+32, uint64(size))
	putTestUint64(data, offset+40, uint64(size))
	putTestUint64(data, offset+48, uint64(alignment))
}

// writeTestSectionHeader writes one ELF64 section header used by debug/elf.
func writeTestSectionHeader(data []byte, offset, name int, kind debugelf.SectionType, fileOffset, size, link, entrySize int) {
	putTestUint32(data, offset, uint32(name))
	putTestUint32(data, offset+4, uint32(kind))
	putTestUint64(data, offset+24, uint64(fileOffset))
	putTestUint64(data, offset+32, uint64(size))
	putTestUint32(data, offset+40, uint32(link))
	putTestUint64(data, offset+56, uint64(entrySize))
}
