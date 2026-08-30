package media

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"sort"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// OpenWriteFunc opens a raw device for writing without truncating or creating it.
type OpenWriteFunc func(string) (WriteDevice, error)

// OpenReadFunc opens a raw device for read-back verification.
type OpenReadFunc func(string) (ReadDevice, error)

// SystemBackendOptions configures host discovery and replaceable raw-device openers.
type SystemBackendOptions struct {
	// Runner executes diskutil, plutil, lsblk, unmount, and ejection commands.
	Runner platform.Runner
	// GOOS selects a supported backend; an empty value uses the running platform.
	GOOS string
	// OpenWrite replaces the standard raw write opener for tests or constrained hosts.
	OpenWrite OpenWriteFunc
	// OpenRead replaces the standard raw read opener for tests or constrained hosts.
	OpenRead OpenReadFunc
}

// systemBackend implements the Darwin and Linux process boundaries without a shell.
type systemBackend struct {
	// runner executes platform commands with distinct arguments.
	runner platform.Runner
	// goos selects the parser and lifecycle commands.
	goos string
	// openWrite opens only the normalised raw path approved by the manager.
	openWrite OpenWriteFunc
	// openRead reopens only the normalised raw path approved by the manager.
	openRead OpenReadFunc
}

// NewSystemBackend selects the Darwin or Linux backend for the requested platform.
func NewSystemBackend(options SystemBackendOptions) (Backend, error) {
	goos := options.GOOS
	if goos == "" {
		goos = runtime.GOOS
	}
	if goos != "darwin" && goos != "linux" {
		return nil, fmt.Errorf("removable-media discovery is unsupported on %s", goos)
	}
	runner := options.Runner
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	return &systemBackend{
		runner: runner, goos: goos, openWrite: options.OpenWrite, openRead: options.OpenRead,
	}, nil
}

// List returns the current whole-device inventory for the selected platform.
func (backend *systemBackend) List(ctx context.Context) ([]Device, error) {
	if err := backend.validate(); err != nil {
		return nil, err
	}
	switch backend.goos {
	case "darwin":
		return backend.listDarwin(ctx)
	case "linux":
		return backend.listLinux(ctx)
	default:
		return nil, fmt.Errorf("removable-media discovery is unsupported on %s", backend.goos)
	}
}

// Inspect returns fresh evidence for one path rather than trusting an earlier list.
func (backend *systemBackend) Inspect(ctx context.Context, path string) (Device, error) {
	if err := backend.validate(); err != nil {
		return Device{}, err
	}
	switch backend.goos {
	case "darwin":
		return backend.inspectDarwin(ctx, path)
	case "linux":
		return backend.inspectLinux(ctx, path)
	default:
		return Device{}, fmt.Errorf("removable-media discovery is unsupported on %s", backend.goos)
	}
}

// Unmount removes any observed target mounts using platform-native commands.
func (backend *systemBackend) Unmount(ctx context.Context, device Device) error {
	if err := backend.validate(); err != nil {
		return err
	}
	switch backend.goos {
	case "darwin":
		if err := backend.runner.Run(ctx, platform.Command{
			Name: "diskutil", Args: []string{"unmountDisk", device.Path},
		}); err != nil {
			return fmt.Errorf("unmount Darwin device %s: %w", device.Path, err)
		}
		return nil
	case "linux":
		if len(device.Mounts) == 0 {
			return nil
		}
		mounts := append([]Mount(nil), device.Mounts...)
		sort.Slice(mounts, func(left, right int) bool {
			return len(mounts[left].Point) > len(mounts[right].Point)
		})
		for _, mount := range mounts {
			if err := backend.runner.Run(ctx, platform.Command{
				Name: "umount", Args: []string{"--", mount.Point},
			}); err != nil {
				return fmt.Errorf("unmount Linux filesystem %s: %w", mount.Point, err)
			}
		}
		return nil
	default:
		return fmt.Errorf("removable-media unmount is unsupported on %s", backend.goos)
	}
}

// OpenWrite opens the raw path from the freshly approved device snapshot.
func (backend *systemBackend) OpenWrite(_ context.Context, device Device) (WriteDevice, error) {
	if err := backend.validate(); err != nil {
		return nil, err
	}
	if backend.openWrite != nil {
		return backend.openWrite(device.RawPath)
	}
	return openRawWrite(device)
}

// OpenRead reopens the raw path from the freshly approved device snapshot.
func (backend *systemBackend) OpenRead(_ context.Context, device Device) (ReadDevice, error) {
	if err := backend.validate(); err != nil {
		return nil, err
	}
	if backend.openRead != nil {
		return backend.openRead(device.RawPath)
	}
	return openRawRead(device)
}

// Eject powers down or ejects a verified whole device through the platform boundary.
func (backend *systemBackend) Eject(ctx context.Context, device Device) error {
	if err := backend.validate(); err != nil {
		return err
	}
	switch backend.goos {
	case "darwin":
		if err := backend.runner.Run(ctx, platform.Command{
			Name: "diskutil", Args: []string{"eject", device.Path},
		}); err != nil {
			return fmt.Errorf("eject Darwin device %s: %w", device.Path, err)
		}
		return nil
	case "linux":
		if err := backend.runner.Run(ctx, platform.Command{
			Name: "udisksctl", Args: []string{"power-off", "--block-device", device.Path},
		}); err != nil {
			return fmt.Errorf("power off Linux device %s: %w", device.Path, err)
		}
		return nil
	default:
		return fmt.Errorf("removable-media ejection is unsupported on %s", backend.goos)
	}
}

// validate confirms that every host boundary has been supplied.
func (backend *systemBackend) validate() error {
	if backend == nil || backend.runner == nil {
		return errors.New("system removable-media command runner is unavailable")
	}
	return nil
}
