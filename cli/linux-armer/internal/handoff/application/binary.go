package application

import (
	"context"
	"crypto/sha256"
	"debug/elf"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const (
	// maximumExecutableBytes bounds the current helper copied into the target.
	maximumExecutableBytes int64 = 256 << 20
)

// binaryArtifact is the exact current executable snapshot used by a plan.
type binaryArtifact struct {
	// path is the resolved non-symlink source path.
	path string
	// sha256 is the lowercase digest rechecked during mutation.
	sha256 string
	// size is the positive source byte length.
	size int64
	// compatible reports Linux ARM64 ELF compatibility.
	compatible bool
}

// inspectCurrentBinary binds Bluetooth installation to this process image while
// allowing an incompatible development host to produce a dry-run plan.
func (manager *Manager) inspectCurrentBinary(ctx context.Context) (binaryArtifact, error) {
	path := manager.executablePath
	if path == "" {
		var err error
		path, err = os.Executable()
		if err != nil {
			return binaryArtifact{}, errors.New("resolve current linux-armer executable")
		}
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return binaryArtifact{}, errors.New("resolve current linux-armer executable")
	}
	info, err := os.Lstat(absolute)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maximumExecutableBytes {
		return binaryArtifact{}, errors.New("current linux-armer executable is not a bounded non-symlink regular file")
	}
	digest, size, err := digestFile(ctx, absolute, maximumExecutableBytes)
	if err != nil || size != info.Size() {
		return binaryArtifact{}, errors.New("inspect current linux-armer executable bytes")
	}
	compatible := manager.runtimeGOOS == "linux" && manager.runtimeGOARCH == "arm64" && isLinuxARM64ELF(absolute)
	return binaryArtifact{path: absolute, sha256: digest, size: size, compatible: compatible}, nil
}

// isLinuxARM64ELF verifies the portable executable shape without executing it.
func isLinuxARM64ELF(path string) bool {
	executable, err := elf.Open(path)
	if err != nil {
		return false
	}
	defer executable.Close()
	if executable.Class != elf.ELFCLASS64 || executable.Data != elf.ELFDATA2LSB || executable.Machine != elf.EM_AARCH64 {
		return false
	}
	if executable.Type != elf.ET_EXEC && executable.Type != elf.ET_DYN {
		return false
	}
	return executable.OSABI == elf.ELFOSABI_NONE || executable.OSABI == elf.ELFOSABI_LINUX
}

// digestFile returns a bounded lowercase SHA-256 and byte count.
func digestFile(ctx context.Context, path string, maximum int64) (string, int64, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	digest := sha256.New()
	written, copyErr := io.Copy(digest, io.LimitReader(contextReader{context: ctx, reader: file}, maximum+1))
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil {
		return "", 0, errors.Join(copyErr, closeErr)
	}
	if written > maximum {
		return "", 0, fmt.Errorf("file exceeds its compiled byte bound")
	}
	return hex.EncodeToString(digest.Sum(nil)), written, nil
}
