//go:build linux

package bluetoothmgmt

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/unix"
)

const (
	// managementDeviceNone binds the kernel-wide HCI control channel.
	managementDeviceNone = 0xffff
	// managementSetPublicAddress is MGMT_OP_SET_PUBLIC_ADDRESS.
	managementSetPublicAddress = 0x0039
	// managementCommandComplete is MGMT_EV_CMD_COMPLETE.
	managementCommandComplete = 0x0001
	// managementCommandStatus is MGMT_EV_CMD_STATUS.
	managementCommandStatus = 0x0002
	// managementSuccess is the kernel management success status.
	managementSuccess = 0x00
	// maximumManagementEventBytes bounds raw kernel event buffers.
	maximumManagementEventBytes = 2048
)

// socketOperations is the narrow syscall boundary used by Linux tests.
type socketOperations interface {
	// Open creates one fresh raw HCI management socket.
	Open() (int, error)
	// SetReadTimeout applies the bounded kernel receive timeout.
	SetReadTimeout(int, time.Duration) error
	// Bind attaches the socket to the HCI control channel.
	Bind(int) error
	// Write sends one complete management request.
	Write(int, []byte) (int, error)
	// Read receives one bounded management event.
	Read(int, []byte) (int, error)
	// Close closes one attempt's socket.
	Close(int) error
}

// unixSocketOperations implements the raw Linux management boundary.
type unixSocketOperations struct{}

// Open creates a close-on-exec raw Bluetooth HCI socket.
func (unixSocketOperations) Open() (int, error) {
	return unix.Socket(unix.AF_BLUETOOTH, unix.SOCK_RAW|unix.SOCK_CLOEXEC, unix.BTPROTO_HCI)
}

// SetReadTimeout configures one kernel receive deadline.
func (unixSocketOperations) SetReadTimeout(descriptor int, timeout time.Duration) error {
	timeval := unix.NsecToTimeval(timeout.Nanoseconds())
	return unix.SetsockoptTimeval(descriptor, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &timeval)
}

// Bind attaches a socket to the kernel-wide HCI management control channel.
func (unixSocketOperations) Bind(descriptor int) error {
	return unix.Bind(descriptor, &unix.SockaddrHCI{Dev: managementDeviceNone, Channel: unix.HCI_CHANNEL_CONTROL})
}

// Write sends raw request bytes without logging them.
func (unixSocketOperations) Write(descriptor int, content []byte) (int, error) {
	return unix.Write(descriptor, content)
}

// Read receives raw response bytes without logging them.
func (unixSocketOperations) Read(descriptor int, content []byte) (int, error) {
	return unix.Read(descriptor, content)
}

// Close releases one raw management socket.
func (unixSocketOperations) Close(descriptor int) error {
	return unix.Close(descriptor)
}

// Set waits for the selected controller and applies its private address through
// fresh, timeout-bounded raw management sockets.
func Set(ctx context.Context, address Address, options Options) error {
	return setWithOperations(ctx, address, options, unixSocketOperations{})
}

// setWithOperations implements bounded retry logic through an injected syscall boundary.
func setWithOperations(ctx context.Context, address Address, options Options, operations socketOperations) error {
	if ctx == nil {
		return errors.New("set private Bluetooth address: context is nil")
	}
	if operations == nil {
		return errors.New("set private Bluetooth address: socket boundary is nil")
	}
	normalised, err := normaliseOptions(options)
	if err != nil {
		return err
	}
	if placeholderAddress(address) || address[0]&0x01 != 0 {
		return errors.New("private Bluetooth address is not an accepted unicast public address")
	}
	if err := waitForController(ctx, normalised); err != nil {
		return err
	}
	request := managementRequest(normalised.ControllerIndex, address)
	for attempt := 0; attempt < normalised.Attempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		if attempt > 0 {
			if err := waitContext(ctx, normalised.RetryDelay); err != nil {
				return err
			}
		}
		accepted, attemptErr := attemptSet(ctx, operations, normalised, request)
		if accepted {
			return nil
		}
		if attemptErr != nil && (errors.Is(attemptErr, context.Canceled) || errors.Is(attemptErr, context.DeadlineExceeded)) {
			return attemptErr
		}
	}
	return errors.New("private Bluetooth address was not accepted after bounded management retries")
}

// waitForController polls only the fixed HCI sysfs presence path within a deadline.
func waitForController(ctx context.Context, options normalisedOptions) error {
	controllerContext, cancel := context.WithTimeout(ctx, options.ControllerWait)
	defer cancel()
	controllerPath := filepath.Join(options.ControllerRoot, fmt.Sprintf("hci%d", options.ControllerIndex))
	for {
		if info, err := os.Stat(controllerPath); err == nil && info.IsDir() {
			return nil
		}
		if err := waitContext(controllerContext, options.PollInterval); err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				return errors.New("Bluetooth controller did not appear within the bounded wait")
			}
			return err
		}
	}
}

// waitContext performs a cancellation-aware retry delay.
func waitContext(ctx context.Context, delay time.Duration) error {
	if delay == 0 {
		return ctx.Err()
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// attemptSet owns one fresh socket, bounded write, and matching response loop.
func attemptSet(ctx context.Context, operations socketOperations, options normalisedOptions, request []byte) (bool, error) {
	descriptor, err := operations.Open()
	if err != nil {
		return false, nil
	}
	defer operations.Close(descriptor)
	if err := operations.SetReadTimeout(descriptor, options.ReadTimeout); err != nil {
		return false, nil
	}
	if err := operations.Bind(descriptor); err != nil {
		return false, nil
	}
	written, err := operations.Write(descriptor, request)
	if err != nil || written != len(request) {
		return false, nil
	}
	readContext, cancel := context.WithTimeout(ctx, options.ReadTimeout)
	defer cancel()
	buffer := make([]byte, maximumManagementEventBytes)
	for {
		if err := readContext.Err(); err != nil {
			return false, nil
		}
		read, err := operations.Read(descriptor, buffer)
		if err != nil {
			if contextErr := readContext.Err(); contextErr != nil {
				return false, contextErr
			}
			return false, nil
		}
		matched, success := parseManagementResponse(buffer[:read], options.ControllerIndex)
		if matched {
			return success, nil
		}
	}
}

// managementRequest encodes the fixed set-public-address opcode and private payload.
func managementRequest(controllerIndex uint16, address Address) []byte {
	request := make([]byte, 12)
	binary.LittleEndian.PutUint16(request[0:2], managementSetPublicAddress)
	binary.LittleEndian.PutUint16(request[2:4], controllerIndex)
	binary.LittleEndian.PutUint16(request[4:6], uint16(len(address)))
	copy(request[6:], address[:])
	return request
}

// parseManagementResponse recognises only complete matching status or completion events.
func parseManagementResponse(event []byte, controllerIndex uint16) (bool, bool) {
	if len(event) < 6 {
		return false, false
	}
	eventCode := binary.LittleEndian.Uint16(event[0:2])
	eventIndex := binary.LittleEndian.Uint16(event[2:4])
	payloadLength := int(binary.LittleEndian.Uint16(event[4:6]))
	if eventIndex != controllerIndex || len(event) < 6+payloadLength {
		return false, false
	}
	payload := event[6 : 6+payloadLength]
	switch eventCode {
	case managementCommandComplete:
		if len(payload) < 3 || binary.LittleEndian.Uint16(payload[0:2]) != managementSetPublicAddress {
			return false, false
		}
		return true, payload[2] == managementSuccess
	case managementCommandStatus:
		if len(payload) < 3 || binary.LittleEndian.Uint16(payload[0:2]) != managementSetPublicAddress {
			return false, false
		}
		return true, payload[2] == managementSuccess
	default:
		return false, false
	}
}
