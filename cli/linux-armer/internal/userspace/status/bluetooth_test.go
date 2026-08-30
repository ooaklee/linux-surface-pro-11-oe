package status

import (
	debugelf "debug/elf"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	handoffapplication "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/handoff/application"
)

// TestNativeBluetoothIntegrationPassesWithoutReadingAddress verifies the exact
// native hand-off paths are recognised and private bytes never reach JSON.
func TestNativeBluetoothIntegrationPassesWithoutReadingAddress(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	secret := "12:34:56:78:9A:BC"
	writeNativeBluetoothIntegrationFixture(t, root, secret)
	report, err := Inspect(Options{Root: root, Features: []Feature{FeatureBluetooth}})
	if err != nil {
		t.Fatal(err)
	}
	check := findCheck(t, report, "bluetooth-native-handoff-integration")
	if check.State != StatePass || !strings.Contains(check.Detail, "value was not read") {
		t.Fatalf("native Bluetooth check = %#v", check)
	}
	if legacy := findCheck(t, report, "bluetooth-legacy-coexistence"); legacy.State != StatePass {
		t.Fatalf("legacy Bluetooth check = %#v", legacy)
	}
	encoded, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), secret) {
		t.Fatalf("native Bluetooth report exposed a private address: %s", encoded)
	}
}

// TestLegacyBluetoothCoexistenceIsExplicit verifies a legacy object alongside
// native hand-off integration is a selected-feature failure with a clear path.
func TestLegacyBluetoothCoexistenceIsExplicit(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	secret := "12:34:56:78:9A:BC"
	writeNativeBluetoothIntegrationFixture(t, root, secret)
	writeFile(t, root, "etc/default/sp11-bluetooth-mac", 0o600, "SP11_BLUETOOTH_MAC=\""+secret+"\"\n")
	report, err := Inspect(Options{Root: root, Features: []Feature{FeatureBluetooth}})
	if err != nil {
		t.Fatal(err)
	}
	check := findCheck(t, report, "bluetooth-legacy-coexistence")
	if check.State != StateFail || !strings.Contains(check.Detail, "coexists with native hand-off integration") || !strings.Contains(check.Detail, "/etc/default/sp11-bluetooth-mac") {
		t.Fatalf("legacy Bluetooth coexistence = %#v", check)
	}
	encoded, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), secret) {
		t.Fatalf("coexistence report exposed a private address: %s", encoded)
	}
}

// TestNativeBluetoothIntegrationFailsClosed verifies partial, weakly protected,
// and incorrectly linked native objects are never reported as complete.
func TestNativeBluetoothIntegrationFailsClosed(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name   string
		mutate func(*testing.T, string)
	}{
		{name: "partial set", mutate: func(t *testing.T, root string) {
			writeFile(t, root, handoffapplication.BluetoothConfigPath, 0o600, "private")
		}},
		{name: "weak private mode", mutate: func(t *testing.T, root string) {
			writeNativeBluetoothIntegrationFixture(t, root, "12:34:56:78:9A:BC")
			if err := os.Chmod(filepath.Join(root, filepath.FromSlash(handoffapplication.BluetoothConfigPath)), 0o644); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "wrong dependency link", mutate: func(t *testing.T, root string) {
			writeNativeBluetoothIntegrationFixture(t, root, "12:34:56:78:9A:BC")
			path := filepath.Join(root, filepath.FromSlash(handoffapplication.BluetoothWantsPath))
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink("../unrelated.service", path); err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			test.mutate(t, root)
			report, err := Inspect(Options{Root: root, Features: []Feature{FeatureBluetooth}})
			if err != nil {
				t.Fatal(err)
			}
			if check := findCheck(t, report, "bluetooth-native-handoff-integration"); check.State != StateFail {
				t.Fatalf("native Bluetooth check = %#v, want selected-feature failure", check)
			}
		})
	}
}

// writeNativeBluetoothIntegrationFixture creates the complete four-object
// native hand-off contract for status tests.
func writeNativeBluetoothIntegrationFixture(t *testing.T, root, secret string) {
	t.Helper()
	writeFile(t, root, handoffapplication.BluetoothConfigPath, 0o600, `{"schema_version":1,"controller_index":0,"address":"`+secret+`"}`)
	writeSyntheticELF(t, root, handoffapplication.InstalledBinaryPath, debugelf.EM_AARCH64, "", nil)
	writeFile(t, root, handoffapplication.BluetoothUnitPath, 0o644, `[Unit]
ConditionPathExists=/etc/linux-armer/private/bluetooth-address.json
Before=bluetooth.service
[Service]
ExecStart=/usr/libexec/linux-armer/linux-armer handoff internal-bluetooth-address
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
`)
	link := filepath.Join(root, filepath.FromSlash(handoffapplication.BluetoothWantsPath))
	mkdir(t, filepath.Dir(link))
	if err := os.Symlink("../linux-armer-sp11-bluetooth-address.service", link); err != nil {
		t.Fatal(err)
	}
}
