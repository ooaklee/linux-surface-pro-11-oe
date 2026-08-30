//go:build linux

package bluetoothmgmt

import (
	"context"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// scriptedSocketOperations is a deterministic raw-management syscall fake.
type scriptedSocketOperations struct {
	// mutex protects observations made by retrying code.
	mutex sync.Mutex
	// responses provides one event sequence for each opened descriptor.
	responses map[int][][]byte
	// openCount records fresh socket attempts.
	openCount int
	// closeCount records released descriptors.
	closeCount int
	// requests retains exact raw request bytes for protocol assertions.
	requests [][]byte
}

// Open allocates one deterministic fake descriptor.
func (operations *scriptedSocketOperations) Open() (int, error) {
	operations.mutex.Lock()
	defer operations.mutex.Unlock()
	operations.openCount++
	return operations.openCount, nil
}

// SetReadTimeout accepts the bounded timeout selected by production logic.
func (*scriptedSocketOperations) SetReadTimeout(int, time.Duration) error {
	return nil
}

// Bind accepts the fixed kernel-wide control-channel binding.
func (*scriptedSocketOperations) Bind(int) error {
	return nil
}

// Write captures one raw management request without formatting its address.
func (operations *scriptedSocketOperations) Write(_ int, content []byte) (int, error) {
	operations.mutex.Lock()
	defer operations.mutex.Unlock()
	operations.requests = append(operations.requests, append([]byte(nil), content...))
	return len(content), nil
}

// Read returns the next scripted event for one fake descriptor.
func (operations *scriptedSocketOperations) Read(descriptor int, buffer []byte) (int, error) {
	operations.mutex.Lock()
	defer operations.mutex.Unlock()
	events := operations.responses[descriptor]
	if len(events) == 0 {
		return 0, errors.New("scripted receive timeout")
	}
	event := events[0]
	operations.responses[descriptor] = events[1:]
	return copy(buffer, event), nil
}

// Close records release of one fake descriptor.
func (operations *scriptedSocketOperations) Close(int) error {
	operations.mutex.Lock()
	defer operations.mutex.Unlock()
	operations.closeCount++
	return nil
}

// TestSetWithOperationsSendsFixedRequestAndRetries verifies exact protocol
// encoding, unrelated-event filtering, fresh sockets, and status retry.
func TestSetWithOperationsSendsFixedRequestAndRetries(t *testing.T) {
	t.Parallel()
	controllerRoot := t.TempDir()
	if err := os.Mkdir(filepath.Join(controllerRoot, "hci7"), 0o755); err != nil {
		t.Fatal(err)
	}
	operations := &scriptedSocketOperations{responses: map[int][][]byte{
		1: {managementEvent(0x9999, 7, nil), managementStatusEvent(7, 0x0b)},
		2: {managementCompleteEvent(7, managementSuccess)},
	}}
	address := Address{0x10, 0x20, 0x30, 0x40, 0x50, 0x60}
	err := setWithOperations(context.Background(), address, Options{
		ControllerIndex: 7, ControllerRoot: controllerRoot,
		ControllerWait: time.Second, PollInterval: time.Millisecond,
		Attempts: 2, RetryDelay: time.Nanosecond, ReadTimeout: time.Second,
	}, operations)
	if err != nil {
		t.Fatal(err)
	}
	if operations.openCount != 2 || operations.closeCount != 2 || len(operations.requests) != 2 {
		t.Fatalf("socket lifecycle = opens %d closes %d requests %d", operations.openCount, operations.closeCount, len(operations.requests))
	}
	want := []byte{0x39, 0x00, 0x07, 0x00, 0x06, 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60}
	for _, request := range operations.requests {
		if string(request) != string(want) {
			t.Fatalf("management request bytes = %v, want %v", request, want)
		}
	}
}

// TestSetWithOperationsBoundsControllerWait verifies absent hardware terminates
// through the caller-visible bounded discovery error.
func TestSetWithOperationsBoundsControllerWait(t *testing.T) {
	t.Parallel()
	address := Address{0x10, 0x20, 0x30, 0x40, 0x50, 0x60}
	operations := &scriptedSocketOperations{responses: make(map[int][][]byte)}
	err := setWithOperations(context.Background(), address, Options{
		ControllerRoot: t.TempDir(), ControllerWait: 5 * time.Millisecond,
		PollInterval: time.Millisecond, Attempts: 1, ReadTimeout: time.Millisecond,
	}, operations)
	if err == nil || operations.openCount != 0 {
		t.Fatalf("absent-controller result = %v, opens %d", err, operations.openCount)
	}
}

// managementEvent encodes one bounded raw HCI management event.
func managementEvent(code, index uint16, payload []byte) []byte {
	event := make([]byte, 6+len(payload))
	binary.LittleEndian.PutUint16(event[0:2], code)
	binary.LittleEndian.PutUint16(event[2:4], index)
	binary.LittleEndian.PutUint16(event[4:6], uint16(len(payload)))
	copy(event[6:], payload)
	return event
}

// managementCompleteEvent encodes one set-public-address completion event.
func managementCompleteEvent(index uint16, status byte) []byte {
	payload := make([]byte, 3)
	binary.LittleEndian.PutUint16(payload[0:2], managementSetPublicAddress)
	payload[2] = status
	return managementEvent(managementCommandComplete, index, payload)
}

// managementStatusEvent encodes one set-public-address status event.
func managementStatusEvent(index uint16, status byte) []byte {
	payload := make([]byte, 3)
	binary.LittleEndian.PutUint16(payload[0:2], managementSetPublicAddress)
	payload[2] = status
	return managementEvent(managementCommandStatus, index, payload)
}
