package bluetoothmgmt

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// TestParseAddressValidatesAndRedacts verifies canonical private address
// decoding without reusable string or diagnostic formatting.
func TestParseAddressValidatesAndRedacts(t *testing.T) {
	t.Parallel()
	address, err := ParseAddress("10:20:30:40:50:60")
	if err != nil {
		t.Fatal(err)
	}
	if address != (Address{0x10, 0x20, 0x30, 0x40, 0x50, 0x60}) {
		t.Fatalf("decoded address bytes = %v", [6]byte(address))
	}
	formatted := fmt.Sprintf("%s %#v", address, address)
	if strings.Contains(formatted, "10:20") || !strings.Contains(formatted, "<redacted>") {
		t.Fatalf("private address formatting = %q", formatted)
	}
	for _, invalid := range []string{
		"10:20:30:40:50", "10-20-30-40-50-60", "10:20:30:40:50:6a",
		"00:00:00:00:00:01", "AA:BB:CC:DD:EE:FF", "11:20:30:40:50:60",
	} {
		_, parseErr := ParseAddress(invalid)
		if parseErr == nil {
			t.Fatalf("ParseAddress() accepted %q", invalid)
		}
		if strings.Contains(parseErr.Error(), invalid) {
			t.Fatalf("ParseAddress() error disclosed rejected private input: %v", parseErr)
		}
	}
}

// TestNormaliseOptionsEnforcesBounds verifies every runtime wait and retry has
// a compiled positive upper bound.
func TestNormaliseOptionsEnforcesBounds(t *testing.T) {
	t.Parallel()
	normalised, err := normaliseOptions(Options{ControllerSelector: SurfacePro11WCN7850UART})
	if err != nil {
		t.Fatal(err)
	}
	if normalised.Attempts != defaultAttempts || normalised.ControllerWait != defaultControllerWait || normalised.ReadTimeout != defaultReadTimeout {
		t.Fatalf("default options = %#v", normalised)
	}
	invalid := []Options{
		{},
		{ControllerSelector: "external-radio"},
		{ControllerSelector: SurfacePro11WCN7850UART, Attempts: maximumAttempts + 1},
		{ControllerSelector: SurfacePro11WCN7850UART, ControllerWait: maximumControllerWait + time.Second},
		{ControllerSelector: SurfacePro11WCN7850UART, ControllerWait: time.Second, PollInterval: 2 * time.Second},
		{ControllerSelector: SurfacePro11WCN7850UART, ReadTimeout: maximumReadTimeout + time.Second},
		{ControllerSelector: SurfacePro11WCN7850UART, RetryDelay: -time.Second},
	}
	for _, options := range invalid {
		if _, err := normaliseOptions(options); err == nil {
			t.Fatalf("normaliseOptions() accepted %#v", options)
		}
	}
}
