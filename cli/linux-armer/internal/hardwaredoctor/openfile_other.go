//go:build !linux && !darwin

package hardwaredoctor

import (
	"errors"
	"fmt"
	"os"
)

// openDiagnosticFile opens a descriptor-relative regular file on platforms
// without Unix non-blocking file flags.
func openDiagnosticFile(root *os.Root, relativePath string) (*os.File, error) {
	info, err := root.Stat(relativePath)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("hardware diagnostic file is not a regular file")
	}
	file, err := root.Open(relativePath)
	if err != nil {
		return nil, err
	}
	openedInfo, statErr := file.Stat()
	if statErr == nil && openedInfo.Mode().IsRegular() {
		return file, nil
	}
	closeErr := file.Close()
	if statErr != nil {
		return nil, errors.Join(statErr, closeErr)
	}
	if closeErr != nil {
		return nil, closeErr
	}
	return nil, fmt.Errorf("hardware diagnostic file changed type while opening")
}
