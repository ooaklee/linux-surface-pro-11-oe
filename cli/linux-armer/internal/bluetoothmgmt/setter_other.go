//go:build !linux

package bluetoothmgmt

import (
	"context"
	"errors"
)

// Set reports that raw HCI management application is Linux-only.
func Set(ctx context.Context, _ Address, _ Options) error {
	if ctx == nil {
		return errors.New("set private Bluetooth address: context is nil")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return errors.New("raw Bluetooth management is supported only on Linux")
}
