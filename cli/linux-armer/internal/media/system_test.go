package media

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"testing"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// scriptedRunner provides deterministic command output without invoking host tools.
type scriptedRunner struct {
	// captures maps an executable and argument vector to captured output.
	captures map[string][]byte
	// captureErrors maps an executable and argument vector to a capture failure.
	captureErrors map[string]error
	// runs records every non-capturing command in execution order.
	runs []platform.Command
	// runError fails the matching non-capturing command when configured.
	runError map[string]error
	// capturesSeen records every capturing command in execution order.
	capturesSeen []platform.Command
}

// Run records one shell-free process request and returns its configured result.
func (runner *scriptedRunner) Run(_ context.Context, command platform.Command) error {
	runner.runs = append(runner.runs, command)
	return runner.runError[commandKey(command)]
}

// Capture returns scripted bytes or passes fake plist bytes through plutil conversion.
func (runner *scriptedRunner) Capture(_ context.Context, command platform.Command) ([]byte, error) {
	runner.capturesSeen = append(runner.capturesSeen, command)
	key := commandKey(command)
	if err := runner.captureErrors[key]; err != nil {
		return nil, err
	}
	if command.Name == "plutil" {
		if command.Stdin == nil {
			return nil, errors.New("plutil input is missing")
		}
		return io.ReadAll(command.Stdin)
	}
	output, exists := runner.captures[key]
	if !exists {
		return nil, fmt.Errorf("unexpected capture command %s", key)
	}
	return append([]byte(nil), output...), nil
}

// commandKey produces one unambiguous key for a shell-free process request.
func commandKey(command platform.Command) string {
	return strings.Join(append([]string{command.Name}, command.Args...), "\x00")
}

// testLinuxInventory returns representative internal-system and removable-USB lsblk data.
func testLinuxInventory() []byte {
	return []byte(`{
  "blockdevices": [
    {
      "name": "/dev/nvme0n1", "path": "/dev/nvme0n1", "kname": "nvme0n1", "pkname": null,
      "maj:min": "259:0", "type": "disk", "size": 1000000, "log-sec": 512, "phy-sec": 4096,
      "model": "Internal SSD", "vendor": "Example", "serial": "internal-serial", "wwn": null,
      "tran": "nvme", "rm": false, "ro": false, "hotplug": false,
      "mountpoints": [null], "fstype": null, "label": null, "uuid": null,
      "children": [
        {
          "name": "/dev/nvme0n1p2", "path": "/dev/nvme0n1p2", "kname": "nvme0n1p2",
          "pkname": "nvme0n1", "maj:min": "259:2", "type": "part", "size": 900000,
          "log-sec": 512, "phy-sec": 4096, "model": null, "vendor": null, "serial": null,
          "wwn": null, "tran": null, "rm": false, "ro": false, "hotplug": false,
          "mountpoints": ["/"], "fstype": "ext4", "label": "root", "uuid": "root-uuid"
        }
      ]
    },
    {
      "name": "/dev/sdb", "path": "/dev/sdb", "kname": "sdb", "pkname": null,
      "maj:min": "8:16", "type": "disk", "size": "64000000", "log-sec": "512", "phy-sec": "4096",
      "model": "Flash Drive", "vendor": "Example", "serial": "usb-serial", "wwn": "usb-wwn",
      "tran": "usb", "rm": 1, "ro": 0, "hotplug": "1",
      "mountpoints": [null], "fstype": null, "label": null, "uuid": null,
      "children": [
        {
          "name": "/dev/sdb1", "path": "/dev/sdb1", "kname": "sdb1", "pkname": "sdb",
          "maj:min": "8:17", "type": "part", "size": 63000000, "log-sec": 512, "phy-sec": 4096,
          "model": null, "vendor": null, "serial": null, "wwn": null, "tran": null,
          "rm": true, "ro": false, "hotplug": true, "mountpoints": ["/media/user/USB"],
          "fstype": "vfat", "label": "USB", "uuid": "usb-filesystem"
        }
      ]
    }
  ]
}`)
}

// TestLinuxBackendMapsSafetyEvidence verifies strict lsblk parsing and descendant mounts.
func TestLinuxBackendMapsSafetyEvidence(t *testing.T) {
	runner := &scriptedRunner{captures: map[string][]byte{
		commandKey(platform.Command{Name: "lsblk", Args: []string{"--json", "--bytes", "--paths", "--output", linuxLSBLKColumns}}): testLinuxInventory(),
	}}
	backendValue, err := NewSystemBackend(SystemBackendOptions{Runner: runner, GOOS: "linux"})
	if err != nil {
		t.Fatal(err)
	}
	devices, err := backendValue.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 2 {
		t.Fatalf("List() returned %d devices: %#v", len(devices), devices)
	}
	internal := devices[0]
	removable := devices[1]
	if internal.Path != "/dev/nvme0n1" || !internal.System || len(internal.Mounts) != 1 || internal.Mounts[0].Point != "/" {
		t.Fatalf("internal device = %#v", internal)
	}
	if removable.Path != "/dev/sdb" || removable.RawPath != "/dev/sdb" || !removable.WholeDisk || !removable.External || !removable.Removable || !removable.USB {
		t.Fatalf("removable device = %#v", removable)
	}
	if removable.StableID != "usb-wwn" || removable.MajorMinor != "8:16" || len(removable.Mounts) != 1 || removable.Mounts[0].Point != "/media/user/USB" {
		t.Fatalf("removable identity and mounts = %#v", removable)
	}
	inspected, err := backendValue.Inspect(context.Background(), "/dev/sdb")
	if err != nil {
		t.Fatal(err)
	}
	if inspected.Path != removable.Path || len(runner.capturesSeen) != 2 {
		t.Fatalf("Inspect() = %#v, capture count = %d", inspected, len(runner.capturesSeen))
	}
	for _, command := range runner.capturesSeen {
		if command.Name != "lsblk" || len(command.Args) != 5 || command.Args[4] != linuxLSBLKColumns {
			t.Fatalf("unexpected Linux discovery command: %#v", command)
		}
	}
}

// TestLinuxBackendRejectsMissingSafetyEvidence verifies lsblk omissions fail closed.
func TestLinuxBackendRejectsMissingSafetyEvidence(t *testing.T) {
	malformed := []byte(`{"blockdevices":[{"path":"/dev/sdb","type":"disk","size":4096,"log-sec":512,"phy-sec":512,"tran":"usb","rm":true,"ro":false,"mountpoints":[]}]}`)
	runner := &scriptedRunner{captures: map[string][]byte{
		commandKey(platform.Command{Name: "lsblk", Args: []string{"--json", "--bytes", "--paths", "--output", linuxLSBLKColumns}}): malformed,
	}}
	backendValue, err := NewSystemBackend(SystemBackendOptions{Runner: runner, GOOS: "linux"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := backendValue.List(context.Background()); err == nil || !strings.Contains(err.Error(), "safety boolean") {
		t.Fatalf("List() error = %v", err)
	}
}

// TestLinuxBackendRejectsMalformedDeviceNumber verifies kernel identity syntax is strict.
func TestLinuxBackendRejectsMalformedDeviceNumber(t *testing.T) {
	malformed := []byte(`{"blockdevices":[{"path":"/dev/sdb","pkname":null,"maj:min":"8:no","type":"disk","size":4096,"log-sec":512,"phy-sec":512,"tran":"usb","rm":true,"ro":false,"hotplug":true,"mountpoints":[]}]}`)
	runner := &scriptedRunner{captures: map[string][]byte{
		commandKey(platform.Command{Name: "lsblk", Args: []string{"--json", "--bytes", "--paths", "--output", linuxLSBLKColumns}}): malformed,
	}}
	backendValue, err := NewSystemBackend(SystemBackendOptions{Runner: runner, GOOS: "linux"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := backendValue.List(context.Background()); err == nil || !strings.Contains(err.Error(), "major:minor") {
		t.Fatalf("List() error = %v", err)
	}
}

// TestLinuxBackendMarksSwapAndMappedDescendantsInUse verifies non-mount block
// consumers cannot be mistaken for an idle removable target.
func TestLinuxBackendMarksSwapAndMappedDescendantsInUse(t *testing.T) {
	for _, test := range []struct {
		name        string
		oldFragment string
		newFragment string
	}{
		{
			name:        "active swap",
			oldFragment: "\"mountpoints\": [\"/media/user/USB\"],\n          \"fstype\": \"vfat\"",
			newFragment: "\"mountpoints\": [\"[SWAP]\"],\n          \"fstype\": \"swap\"",
		},
		{
			name:        "mapped descendant",
			oldFragment: `"maj:min": "8:17", "type": "part"`,
			newFragment: `"maj:min": "8:17", "type": "crypt"`,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			inventory := bytes.Replace(
				testLinuxInventory(),
				[]byte(test.oldFragment),
				[]byte(test.newFragment),
				1,
			)
			if bytes.Equal(inventory, testLinuxInventory()) {
				t.Fatalf("fixture fragment %q was not found", test.oldFragment)
			}
			runner := &scriptedRunner{captures: map[string][]byte{
				commandKey(platform.Command{Name: "lsblk", Args: []string{"--json", "--bytes", "--paths", "--output", linuxLSBLKColumns}}): inventory,
			}}
			backendValue, err := NewSystemBackend(SystemBackendOptions{Runner: runner, GOOS: "linux"})
			if err != nil {
				t.Fatal(err)
			}
			devices, err := backendValue.List(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if len(devices) != 2 || !devices[1].InUse {
				t.Fatalf("USB device was not marked in use: %#v", devices)
			}
			if test.name == "active swap" && len(devices[1].Mounts) != 0 {
				t.Fatalf("swap pseudo-mount became an ordinary mount: %#v", devices[1].Mounts)
			}
		})
	}
}

// TestLinuxBackendRejectsMissingChildUsageEvidence verifies every descendant,
// not only the whole disk, must include the requested mountpoint evidence.
func TestLinuxBackendRejectsMissingChildUsageEvidence(t *testing.T) {
	inventory := bytes.Replace(
		testLinuxInventory(),
		[]byte(`"mountpoints": ["/media/user/USB"]`),
		[]byte(`"unexpected-mountpoints": ["/media/user/USB"]`),
		1,
	)
	runner := &scriptedRunner{captures: map[string][]byte{
		commandKey(platform.Command{Name: "lsblk", Args: []string{"--json", "--bytes", "--paths", "--output", linuxLSBLKColumns}}): inventory,
	}}
	backendValue, err := NewSystemBackend(SystemBackendOptions{Runner: runner, GOOS: "linux"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := backendValue.List(context.Background()); err == nil || !strings.Contains(err.Error(), "omitted mountpoints") {
		t.Fatalf("List() error = %v", err)
	}
}

// darwinFixture contains one physical inventory response and per-object information.
type darwinFixture struct {
	// Physical is the physical-only diskutil list document.
	Physical []byte
	// Complete is the complete diskutil list document.
	Complete []byte
	// Info maps short device identifiers to diskutil information documents.
	Info map[string][]byte
}

// testDarwinFixture returns an APFS-backed system disk and one mounted USB disk.
func testDarwinFixture() darwinFixture {
	physical := []byte(`{
  "AllDisks":["disk0","disk2"], "WholeDisks":["disk0","disk2"],
  "AllDisksAndPartitions":[
    {"DeviceIdentifier":"disk0","Partitions":[{"DeviceIdentifier":"disk0s2"}]},
    {"DeviceIdentifier":"disk2","Partitions":[{"DeviceIdentifier":"disk2s1"}]}
  ]
}`)
	complete := []byte(`{
  "AllDisks":["disk0","disk0s2","disk2","disk2s1","disk3","disk3s1"],
  "AllDisksAndPartitions":[
    {"DeviceIdentifier":"disk0","Partitions":[{"DeviceIdentifier":"disk0s2"}]},
    {"DeviceIdentifier":"disk2","Partitions":[{"DeviceIdentifier":"disk2s1"}]},
		{"DeviceIdentifier":"disk3","APFSPhysicalStores":[{"DeviceIdentifier":"disk0s2"}],"APFSVolumes":[{"DeviceIdentifier":"disk3s1"}]}
  ]
}`)
	return darwinFixture{Physical: physical, Complete: complete, Info: map[string][]byte{
		"disk0":   []byte(`{"DeviceIdentifier":"disk0","DeviceNode":"/dev/disk0","Whole":true,"Internal":true,"RemovableMedia":false,"WritableMedia":true,"Mounted":false,"BusProtocol":"PCI-Express","VirtualOrPhysical":"Unknown","TotalSize":1000000,"DeviceBlockSize":512,"PhysicalBlockSize":4096,"MediaName":"Internal SSD","DeviceTreePath":"IODeviceTree:/internal","DiskUUID":"internal-uuid"}`),
		"disk0s2": []byte(`{"DeviceIdentifier":"disk0s2","DeviceNode":"/dev/disk0s2","ParentWholeDisk":"disk0","Whole":false,"Mounted":false}`),
		"disk2":   []byte(`{"DeviceIdentifier":"disk2","DeviceNode":"/dev/disk2","Whole":true,"Internal":false,"RemovableMedia":true,"WritableMedia":true,"Mounted":false,"BusProtocol":"USB","VirtualOrPhysical":"Physical","TotalSize":64000000,"DeviceBlockSize":512,"PhysicalBlockSize":4096,"MediaName":"Flash Drive","DeviceTreePath":"IODeviceTree:/usb/2","MediaUUID":"usb-media-uuid"}`),
		"disk2s1": []byte(`{"DeviceIdentifier":"disk2s1","DeviceNode":"/dev/disk2s1","ParentWholeDisk":"disk2","Whole":false,"Mounted":true,"MountPoint":"/Volumes/USB","FilesystemType":"msdos","VolumeName":"USB","Writable":true}`),
		"disk3":   []byte(`{"DeviceIdentifier":"disk3","DeviceNode":"/dev/disk3","Whole":true,"Mounted":false}`),
		"disk3s1": []byte(`{"DeviceIdentifier":"disk3s1","DeviceNode":"/dev/disk3s1","ParentWholeDisk":"disk3","Whole":false,"Mounted":true,"MountPoint":"/","FilesystemType":"apfs","VolumeName":"System","Writable":true}`),
	}}
}

// darwinRunner converts a fixture into the exact diskutil command-response map.
func darwinRunner(fixture darwinFixture) *scriptedRunner {
	captures := map[string][]byte{
		commandKey(platform.Command{Name: "diskutil", Args: []string{"list", "-plist", "physical"}}): fixture.Physical,
		commandKey(platform.Command{Name: "diskutil", Args: []string{"list", "-plist"}}):             fixture.Complete,
	}
	for identifier, info := range fixture.Info {
		captures[commandKey(platform.Command{Name: "diskutil", Args: []string{"info", "-plist", "/dev/" + identifier}})] = info
	}
	return &scriptedRunner{captures: captures}
}

// TestDarwinBackendMapsPhysicalAndAPFSEvidence verifies plist conversion and graph resolution.
func TestDarwinBackendMapsPhysicalAndAPFSEvidence(t *testing.T) {
	runner := darwinRunner(testDarwinFixture())
	backendValue, err := NewSystemBackend(SystemBackendOptions{Runner: runner, GOOS: "darwin"})
	if err != nil {
		t.Fatal(err)
	}
	devices, err := backendValue.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 2 {
		t.Fatalf("List() returned %d devices: %#v", len(devices), devices)
	}
	if devices[0].Path != "/dev/disk0" || devices[0].RawPath != "/dev/rdisk0" || !devices[0].System || len(devices[0].Mounts) != 1 || devices[0].Mounts[0].Point != "/" {
		t.Fatalf("Darwin system device = %#v", devices[0])
	}
	if devices[0].StableID != "" {
		t.Fatalf("content-derived Darwin disk UUID became stable identity: %#v", devices[0])
	}
	if devices[1].Path != "/dev/disk2" || devices[1].RawPath != "/dev/rdisk2" || !devices[1].External || !devices[1].Removable || !devices[1].USB || len(devices[1].Mounts) != 1 {
		t.Fatalf("Darwin USB device = %#v", devices[1])
	}
	if devices[1].StableID != "usb-media-uuid" || devices[1].Mounts[0].Device != "/dev/disk2s1" || devices[1].Mounts[0].Point != "/Volumes/USB" {
		t.Fatalf("Darwin USB identity and mounts = %#v", devices[1])
	}
	if len(runner.capturesSeen) != 16 {
		t.Fatalf("capture count = %d, want 16", len(runner.capturesSeen))
	}
	for index, command := range runner.capturesSeen {
		if index%2 == 0 && command.Name != "diskutil" {
			t.Fatalf("capture %d = %#v, want diskutil", index, command)
		}
		if index%2 == 1 && (command.Name != "plutil" || command.Stdin == nil) {
			t.Fatalf("capture %d = %#v, want plutil with stdin", index, command)
		}
	}
}

// TestDarwinBackendRejectsMissingSafetyEvidence verifies physical media fails closed.
func TestDarwinBackendRejectsMissingSafetyEvidence(t *testing.T) {
	fixture := testDarwinFixture()
	fixture.Info["disk2"] = []byte(`{"DeviceIdentifier":"disk2","DeviceNode":"/dev/disk2","Whole":true,"Internal":false,"WritableMedia":true,"Mounted":false,"BusProtocol":"USB","VirtualOrPhysical":"Physical","TotalSize":64000000}`)
	backendValue, err := NewSystemBackend(SystemBackendOptions{Runner: darwinRunner(fixture), GOOS: "darwin"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := backendValue.List(context.Background()); err == nil || !strings.Contains(err.Error(), "safety classification") {
		t.Fatalf("List() error = %v", err)
	}
}

// TestDarwinBackendRejectsExplicitVirtualMedia verifies physical-list inconsistencies fail closed.
func TestDarwinBackendRejectsExplicitVirtualMedia(t *testing.T) {
	fixture := testDarwinFixture()
	fixture.Info["disk2"] = []byte(`{"DeviceIdentifier":"disk2","DeviceNode":"/dev/disk2","Whole":true,"Internal":false,"RemovableMedia":true,"WritableMedia":true,"Mounted":false,"BusProtocol":"USB","VirtualOrPhysical":"Virtual","TotalSize":64000000}`)
	backendValue, err := NewSystemBackend(SystemBackendOptions{Runner: darwinRunner(fixture), GOOS: "darwin"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := backendValue.List(context.Background()); err == nil || !strings.Contains(err.Error(), "explicitly virtual") {
		t.Fatalf("List() error = %v", err)
	}
}

// TestDarwinBackendRejectsUnresolvedMountedPhysicalEvidence verifies an
// unclassified mounted disk cannot disappear from whole-device usage evidence.
func TestDarwinBackendRejectsUnresolvedMountedPhysicalEvidence(t *testing.T) {
	fixture := testDarwinFixture()
	fixture.Complete = bytes.Replace(
		fixture.Complete,
		[]byte(`"disk3","disk3s1"`),
		[]byte(`"disk3","disk3s1","disk4"`),
		1,
	)
	fixture.Info["disk4"] = []byte(`{"DeviceIdentifier":"disk4","DeviceNode":"/dev/disk4","Whole":true,"Mounted":true,"MountPoint":"/Volumes/Mystery","VirtualOrPhysical":"Unknown"}`)
	backendValue, err := NewSystemBackend(SystemBackendOptions{Runner: darwinRunner(fixture), GOOS: "darwin"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := backendValue.List(context.Background()); err == nil || !strings.Contains(err.Error(), "could not resolve the physical disk backing mounted") {
		t.Fatalf("List() error = %v", err)
	}
}

// TestDarwinBackendIgnoresExplicitVirtualMounts verifies mounted disk images do
// not prevent safe inventory when diskutil explicitly classifies them virtual.
func TestDarwinBackendIgnoresExplicitVirtualMounts(t *testing.T) {
	fixture := testDarwinFixture()
	fixture.Complete = bytes.Replace(
		fixture.Complete,
		[]byte(`"disk3","disk3s1"`),
		[]byte(`"disk3","disk3s1","disk4"`),
		1,
	)
	fixture.Info["disk4"] = []byte(`{"DeviceIdentifier":"disk4","DeviceNode":"/dev/disk4","Whole":true,"Mounted":true,"MountPoint":"/Volumes/Image","VirtualOrPhysical":"Virtual"}`)
	backendValue, err := NewSystemBackend(SystemBackendOptions{Runner: darwinRunner(fixture), GOOS: "darwin"})
	if err != nil {
		t.Fatal(err)
	}
	devices, err := backendValue.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 2 {
		t.Fatalf("List() returned %d physical devices: %#v", len(devices), devices)
	}
}

// inertWriteDevice provides a no-op raw writer for system-boundary tests.
type inertWriteDevice struct {
	// bytes.Buffer retains any bytes supplied by a caller.
	bytes.Buffer
}

// Sync completes the no-op durability boundary.
func (*inertWriteDevice) Sync() error { return nil }

// Close completes the no-op write boundary.
func (*inertWriteDevice) Close() error { return nil }

// inertReadDevice provides an empty raw reader for system-boundary tests.
type inertReadDevice struct {
	// Reader supplies deterministic empty input.
	*bytes.Reader
}

// Close completes the no-op read boundary.
func (*inertReadDevice) Close() error { return nil }

// TestSystemBackendUsesExplicitLifecycleBoundaries verifies argument ordering and openers.
func TestSystemBackendUsesExplicitLifecycleBoundaries(t *testing.T) {
	runner := &scriptedRunner{}
	var writePath, readPath string
	backendValue, err := NewSystemBackend(SystemBackendOptions{
		Runner: runner, GOOS: "linux",
		OpenWrite: func(path string) (WriteDevice, error) {
			writePath = path
			return &inertWriteDevice{}, nil
		},
		OpenRead: func(path string) (ReadDevice, error) {
			readPath = path
			return &inertReadDevice{Reader: bytes.NewReader(nil)}, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	device := safeTestDevice(4096)
	device.Mounts = []Mount{
		{Device: "/dev/test-disk2s1", Point: "/media/usb"},
		{Device: "/dev/mapper/nested", Point: "/media/usb/nested"},
	}
	if err := backendValue.Unmount(context.Background(), device); err != nil {
		t.Fatal(err)
	}
	if _, err := backendValue.OpenWrite(context.Background(), device); err != nil {
		t.Fatal(err)
	}
	if _, err := backendValue.OpenRead(context.Background(), device); err != nil {
		t.Fatal(err)
	}
	if err := backendValue.Eject(context.Background(), device); err != nil {
		t.Fatal(err)
	}
	if writePath != device.RawPath || readPath != device.RawPath {
		t.Fatalf("raw opener paths = write %q, read %q", writePath, readPath)
	}
	want := []platform.Command{
		{Name: "umount", Args: []string{"--", "/media/usb/nested"}},
		{Name: "umount", Args: []string{"--", "/media/usb"}},
		{Name: "udisksctl", Args: []string{"power-off", "--block-device", device.Path}},
	}
	if len(runner.runs) != len(want) {
		t.Fatalf("lifecycle commands = %#v", runner.runs)
	}
	for index := range want {
		if commandKey(runner.runs[index]) != commandKey(want[index]) {
			t.Fatalf("lifecycle command %d = %#v, want %#v", index, runner.runs[index], want[index])
		}
	}
	if _, err := NewSystemBackend(SystemBackendOptions{GOOS: "windows"}); err == nil || !strings.Contains(err.Error(), "unsupported") {
		t.Fatalf("unsupported platform error = %v", err)
	}
}

// TestDarwinBackendUsesDiskutilLifecycle verifies whole-disk preparation and ejection.
func TestDarwinBackendUsesDiskutilLifecycle(t *testing.T) {
	runner := &scriptedRunner{}
	backendValue, err := NewSystemBackend(SystemBackendOptions{Runner: runner, GOOS: "darwin"})
	if err != nil {
		t.Fatal(err)
	}
	device := safeTestDevice(4096)
	device.Path = "/dev/disk2"
	device.RawPath = "/dev/rdisk2"
	device.Mounts = []Mount{{Device: "/dev/disk2s1", Point: "/Volumes/USB"}}
	if err := backendValue.Unmount(context.Background(), device); err != nil {
		t.Fatal(err)
	}
	if err := backendValue.Eject(context.Background(), device); err != nil {
		t.Fatal(err)
	}
	want := []platform.Command{
		{Name: "diskutil", Args: []string{"unmountDisk", "/dev/disk2"}},
		{Name: "diskutil", Args: []string{"eject", "/dev/disk2"}},
	}
	if len(runner.runs) != len(want) {
		t.Fatalf("Darwin lifecycle commands = %#v", runner.runs)
	}
	for index := range want {
		if commandKey(runner.runs[index]) != commandKey(want[index]) {
			t.Fatalf("Darwin lifecycle command %d = %#v, want %#v", index, runner.runs[index], want[index])
		}
	}
}

// TestDarwinBackendPreparesAnApparentlyUnmountedDisk verifies diskutil still
// receives a whole-disk unmount request to detach hidden logical consumers.
func TestDarwinBackendPreparesAnApparentlyUnmountedDisk(t *testing.T) {
	runner := &scriptedRunner{}
	backendValue, err := NewSystemBackend(SystemBackendOptions{Runner: runner, GOOS: "darwin"})
	if err != nil {
		t.Fatal(err)
	}
	device := safeTestDevice(4096)
	device.Path = "/dev/disk2"
	device.RawPath = "/dev/rdisk2"
	device.Mounts = []Mount{}
	if err := backendValue.Unmount(context.Background(), device); err != nil {
		t.Fatal(err)
	}
	want := platform.Command{Name: "diskutil", Args: []string{"unmountDisk", "/dev/disk2"}}
	if len(runner.runs) != 1 || commandKey(runner.runs[0]) != commandKey(want) {
		t.Fatalf("Darwin preparation commands = %#v, want %#v", runner.runs, want)
	}
}
