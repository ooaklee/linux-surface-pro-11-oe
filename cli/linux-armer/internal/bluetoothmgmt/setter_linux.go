//go:build linux

package bluetoothmgmt

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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
	// maximumControllerInventory bounds one kernel HCI class scan.
	maximumControllerInventory = 32
	// maximumCompatibleBytes bounds one device-tree compatibility property.
	maximumCompatibleBytes int64 = 4096
	// surfacePro11BluetoothCompatible is the exact built-in WCN7850 DT identity.
	surfacePro11BluetoothCompatible = "qcom,wcn7850-bt"
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
	for attempt := 0; attempt < normalised.Attempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		if attempt > 0 {
			if err := waitContext(ctx, normalised.RetryDelay); err != nil {
				return err
			}
		}
		controllerIndex, err := waitForController(ctx, normalised)
		if err != nil {
			return err
		}
		request := managementRequest(controllerIndex, address)
		accepted, attemptErr := attemptSet(ctx, operations, normalised, controllerIndex, request)
		if accepted {
			return nil
		}
		if attemptErr != nil && (errors.Is(attemptErr, context.Canceled) || errors.Is(attemptErr, context.DeadlineExceeded)) {
			return attemptErr
		}
	}
	return errors.New("private Bluetooth address was not accepted after bounded management retries")
}

// waitForController polls the bounded HCI inventory until exactly one
// controller satisfies the compiled physical-radio selector.
func waitForController(ctx context.Context, options normalisedOptions) (uint16, error) {
	controllerContext, cancel := context.WithTimeout(ctx, options.ControllerWait)
	defer cancel()
	for {
		controllerIndex, found, err := selectController(options.ControllerRoot, options.ControllerSelector)
		if err != nil {
			return 0, err
		}
		if found {
			return controllerIndex, nil
		}
		if err := waitContext(controllerContext, options.PollInterval); err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				return 0, errors.New("the selected Surface Pro 11 Bluetooth controller did not appear within the bounded wait")
			}
			return 0, err
		}
	}
}

// selectController returns the sole HCI index whose device-tree compatibility
// property proves it is the built-in Surface Pro 11 WCN7850 UART radio.
func selectController(controllerRoot string, selector ControllerSelector) (uint16, bool, error) {
	if selector != SurfacePro11WCN7850UART {
		return 0, false, errors.New("Bluetooth controller selector is unsupported")
	}
	entries, err := os.ReadDir(controllerRoot)
	if errors.Is(err, os.ErrNotExist) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, errors.New("inspect Bluetooth controller inventory")
	}
	if len(entries) > maximumControllerInventory {
		return 0, false, errors.New("Bluetooth controller inventory exceeds its compiled bound")
	}
	candidates := make([]uint16, 0, 1)
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "hci") || len(name) <= len("hci") {
			continue
		}
		parsed, parseErr := strconv.ParseUint(name[len("hci"):], 10, 16)
		if parseErr != nil || strconv.FormatUint(parsed, 10) != name[len("hci"):] {
			continue
		}
		compatiblePath := filepath.Join(controllerRoot, name, "device", "of_node", "compatible")
		matched, matchErr := compatiblePropertyContains(compatiblePath, surfacePro11BluetoothCompatible)
		if matchErr != nil {
			return 0, false, matchErr
		}
		if matched {
			candidates = append(candidates, uint16(parsed))
		}
	}
	if len(candidates) > 1 {
		return 0, false, errors.New("more than one Bluetooth controller matches the compiled Surface Pro 11 selector")
	}
	if len(candidates) == 0 {
		return 0, false, nil
	}
	return candidates[0], true, nil
}

// compatiblePropertyContains reads one bounded NUL-delimited device-tree
// compatibility property and performs an exact token comparison.
func compatiblePropertyContains(path, expected string) (bool, error) {
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, errors.New("open Bluetooth device-tree compatibility evidence")
	}
	content, readErr := io.ReadAll(io.LimitReader(file, maximumCompatibleBytes+1))
	closeErr := file.Close()
	if readErr != nil || closeErr != nil || int64(len(content)) > maximumCompatibleBytes {
		return false, errors.New("read bounded Bluetooth device-tree compatibility evidence")
	}
	if len(content) == 0 || content[len(content)-1] != 0 {
		return false, nil
	}
	for _, token := range strings.Split(string(content[:len(content)-1]), "\x00") {
		if token == expected {
			return true, nil
		}
	}
	return false, nil
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
func attemptSet(ctx context.Context, operations socketOperations, options normalisedOptions, controllerIndex uint16, request []byte) (bool, error) {
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
		matched, success := parseManagementResponse(buffer[:read], controllerIndex)
		if matched {
			return success, nil
		}
	}
}

// managementRequest encodes the fixed set-public-address opcode and reverses
// display-order address octets into the kernel's bdaddr_t wire representation.
func managementRequest(controllerIndex uint16, address Address) []byte {
	request := make([]byte, 12)
	binary.LittleEndian.PutUint16(request[0:2], managementSetPublicAddress)
	binary.LittleEndian.PutUint16(request[2:4], controllerIndex)
	binary.LittleEndian.PutUint16(request[4:6], uint16(len(address)))
	for index := range address {
		request[6+index] = address[len(address)-1-index]
	}
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
