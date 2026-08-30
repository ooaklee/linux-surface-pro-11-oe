package application

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/bluetoothmgmt"
)

const (
	// maximumBluetoothConfigBytes bounds the private fixed-path local config.
	maximumBluetoothConfigBytes int64 = 512
)

// ReadBluetoothRuntimeConfig strictly reads the fixed private target config and
// returns redacted address bytes plus the compiled physical-radio selector.
func ReadBluetoothRuntimeConfig(ctx context.Context, targetRoot string) (bluetoothmgmt.Address, bluetoothmgmt.ControllerSelector, error) {
	if ctx == nil {
		return bluetoothmgmt.Address{}, "", errors.New("read private Bluetooth configuration: context is nil")
	}
	resolvedRoot, err := resolveExplicitRoot(targetRoot, "Bluetooth runtime root", true)
	if err != nil {
		return bluetoothmgmt.Address{}, "", err
	}
	root, err := os.OpenRoot(resolvedRoot)
	if err != nil {
		return bluetoothmgmt.Address{}, "", errors.New("open Bluetooth runtime root")
	}
	defer root.Close()
	info, err := root.Lstat(BluetoothConfigPath)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() <= 0 || info.Size() > maximumBluetoothConfigBytes {
		return bluetoothmgmt.Address{}, "", errors.New("private Bluetooth configuration is not a protected bounded regular file")
	}
	file, err := root.Open(BluetoothConfigPath)
	if err != nil {
		return bluetoothmgmt.Address{}, "", errors.New("open private Bluetooth configuration")
	}
	content, readErr := io.ReadAll(io.LimitReader(contextReader{context: ctx, reader: file}, maximumBluetoothConfigBytes+1))
	closeErr := file.Close()
	if readErr != nil || closeErr != nil || int64(len(content)) > maximumBluetoothConfigBytes {
		return bluetoothmgmt.Address{}, "", errors.New("read private Bluetooth configuration")
	}
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.DisallowUnknownFields()
	var config bluetoothConfig
	if err := decoder.Decode(&config); err != nil {
		return bluetoothmgmt.Address{}, "", errors.New("decode private Bluetooth configuration")
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return bluetoothmgmt.Address{}, "", errors.New("private Bluetooth configuration contains trailing JSON")
	}
	if config.SchemaVersion != 2 || config.ControllerSelector != bluetoothmgmt.SurfacePro11WCN7850UART {
		return bluetoothmgmt.Address{}, "", errors.New("private Bluetooth configuration schema or controller selector is unsupported")
	}
	address, err := bluetoothmgmt.ParseAddress(string(config.Address))
	if err != nil {
		return bluetoothmgmt.Address{}, "", err
	}
	return address, config.ControllerSelector, nil
}
