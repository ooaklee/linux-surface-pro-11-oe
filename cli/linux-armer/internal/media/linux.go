package media

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// linuxLSBLKColumns is the complete discovery schema requested from lsblk.
const linuxLSBLKColumns = "NAME,PATH,KNAME,PKNAME,MAJ:MIN,TYPE,SIZE,LOG-SEC,PHY-SEC,MODEL,VENDOR,SERIAL,WWN,TRAN,RM,RO,HOTPLUG,MOUNTPOINTS,FSTYPE,LABEL,UUID"

// flexibleBool decodes the boolean, number, and string forms emitted by lsblk versions.
type flexibleBool struct {
	// Present distinguishes an explicit false value from a missing safety field.
	Present bool
	// Value is the decoded boolean value.
	Value bool
}

// UnmarshalJSON decodes one strict boolean-compatible lsblk value.
func (value *flexibleBool) UnmarshalJSON(data []byte) error {
	value.Present = true
	text := strings.TrimSpace(string(data))
	switch text {
	case "true", "1", `"1"`, `"true"`:
		value.Value = true
		return nil
	case "false", "0", `"0"`, `"false"`:
		value.Value = false
		return nil
	default:
		return fmt.Errorf("expected a boolean or zero/one, got %s", text)
	}
}

// flexibleUint decodes the numeric or quoted unsigned integer forms emitted by lsblk.
type flexibleUint struct {
	// Present distinguishes zero from a missing size field.
	Present bool
	// Value is the decoded unsigned integer.
	Value uint64
}

// UnmarshalJSON decodes one strict unsigned-integer-compatible lsblk value.
func (value *flexibleUint) UnmarshalJSON(data []byte) error {
	value.Present = true
	text := strings.Trim(strings.TrimSpace(string(data)), `"`)
	parsed, err := strconv.ParseUint(text, 10, 64)
	if err != nil {
		return fmt.Errorf("expected an unsigned integer, got %q", text)
	}
	value.Value = parsed
	return nil
}

// optionalString distinguishes missing, null, and textual lsblk values.
type optionalString struct {
	// Present reports whether the JSON object contained this field.
	Present bool
	// Null reports whether the field contained JSON null.
	Null bool
	// Value is the decoded text when Null is false.
	Value string
}

// UnmarshalJSON decodes one nullable string while preserving field presence.
func (value *optionalString) UnmarshalJSON(data []byte) error {
	value.Present = true
	if strings.TrimSpace(string(data)) == "null" {
		value.Null = true
		value.Value = ""
		return nil
	}
	if err := json.Unmarshal(data, &value.Value); err != nil {
		return fmt.Errorf("expected a string or null: %w", err)
	}
	return nil
}

// linuxMountPoints decodes lsblk's nullable array of nullable mount paths.
type linuxMountPoints struct {
	// Present reports whether lsblk returned the requested mountpoints field.
	Present bool
	// Values contains every non-null mount path in source order.
	Values []string
}

// UnmarshalJSON decodes a nullable mountpoint array without accepting other types.
func (points *linuxMountPoints) UnmarshalJSON(data []byte) error {
	points.Present = true
	if strings.TrimSpace(string(data)) == "null" {
		points.Values = nil
		return nil
	}
	var decoded []*string
	if err := json.Unmarshal(data, &decoded); err != nil {
		return fmt.Errorf("expected a mountpoint array or null: %w", err)
	}
	points.Values = nil
	for _, point := range decoded {
		if point != nil && strings.TrimSpace(*point) != "" {
			points.Values = append(points.Values, *point)
		}
	}
	return nil
}

// linuxDocument is the top-level lsblk JSON envelope.
type linuxDocument struct {
	// BlockDevices contains the root nodes of the block-device tree.
	BlockDevices []linuxBlockDevice `json:"blockdevices"`
}

// linuxBlockDevice models the lsblk fields needed for fail-closed media policy.
type linuxBlockDevice struct {
	// Name is lsblk's operating-system device name.
	Name optionalString `json:"name"`
	// Path is lsblk's absolute device path.
	Path optionalString `json:"path"`
	// KernelName is the kernel's short device name.
	KernelName optionalString `json:"kname"`
	// ParentKernelName identifies the direct parent block device.
	ParentKernelName optionalString `json:"pkname"`
	// MajorMinor is the kernel major-and-minor device number.
	MajorMinor optionalString `json:"maj:min"`
	// Type identifies disks, partitions, loops, and other block objects.
	Type optionalString `json:"type"`
	// Size is the exact capacity in bytes.
	Size flexibleUint `json:"size"`
	// LogicalBlockSize is the logical block size in bytes.
	LogicalBlockSize flexibleUint `json:"log-sec"`
	// PhysicalBlockSize is the physical block size in bytes.
	PhysicalBlockSize flexibleUint `json:"phy-sec"`
	// Model is the reported device model.
	Model optionalString `json:"model"`
	// Vendor is the reported device vendor.
	Vendor optionalString `json:"vendor"`
	// Serial is the reported serial number.
	Serial optionalString `json:"serial"`
	// WWN is the reported world-wide name.
	WWN optionalString `json:"wwn"`
	// Transport identifies the device bus.
	Transport optionalString `json:"tran"`
	// Removable is lsblk's removable-media classification.
	Removable flexibleBool `json:"rm"`
	// ReadOnly is lsblk's whole-device read-only classification.
	ReadOnly flexibleBool `json:"ro"`
	// Hotplug is lsblk's externally hot-pluggable classification.
	Hotplug flexibleBool `json:"hotplug"`
	// MountPoints contains every filesystem mount reported for this node.
	MountPoints linuxMountPoints `json:"mountpoints"`
	// Filesystem is the node's filesystem type when available.
	Filesystem optionalString `json:"fstype"`
	// Label is the node's filesystem label when available.
	Label optionalString `json:"label"`
	// UUID is the node's filesystem or partition UUID when available.
	UUID optionalString `json:"uuid"`
	// Children contains partitions and mappings backed by this node.
	Children []linuxBlockDevice `json:"children"`
}

// listLinux invokes lsblk once and returns every normalised whole disk.
func (backend *systemBackend) listLinux(ctx context.Context) ([]Device, error) {
	document, err := backend.captureLinux(ctx)
	if err != nil {
		return nil, err
	}
	var devices []Device
	for index := range document.BlockDevices {
		if err := collectLinuxDisks(&document.BlockDevices[index], &devices); err != nil {
			return nil, err
		}
	}
	return devices, nil
}

// inspectLinux invokes a fresh lsblk snapshot and resolves one exact path.
func (backend *systemBackend) inspectLinux(ctx context.Context, path string) (Device, error) {
	document, err := backend.captureLinux(ctx)
	if err != nil {
		return Device{}, err
	}
	wanted := filepath.Clean(path)
	for index := range document.BlockDevices {
		if node := findLinuxNode(&document.BlockDevices[index], wanted); node != nil {
			return linuxDevice(*node)
		}
	}
	return Device{}, fmt.Errorf("Linux block device %s was not found", wanted)
}

// captureLinux executes lsblk without a shell and decodes its JSON envelope.
func (backend *systemBackend) captureLinux(ctx context.Context) (linuxDocument, error) {
	output, err := backend.runner.Capture(ctx, platform.Command{
		Name: "lsblk",
		Args: []string{"--json", "--bytes", "--paths", "--output", linuxLSBLKColumns},
	})
	if err != nil {
		return linuxDocument{}, fmt.Errorf("capture Linux block-device inventory: %w", err)
	}
	var document linuxDocument
	if err := json.Unmarshal(output, &document); err != nil {
		return linuxDocument{}, fmt.Errorf("decode Linux block-device inventory: %w", err)
	}
	if document.BlockDevices == nil {
		return linuxDocument{}, errors.New("Linux block-device inventory omitted blockdevices")
	}
	return document, nil
}

// collectLinuxDisks recursively converts disk nodes while retaining their child mounts.
func collectLinuxDisks(node *linuxBlockDevice, devices *[]Device) error {
	if node.Type.Present && !node.Type.Null && node.Type.Value == "disk" {
		device, err := linuxDevice(*node)
		if err != nil {
			return err
		}
		*devices = append(*devices, device)
	}
	for index := range node.Children {
		if err := collectLinuxDisks(&node.Children[index], devices); err != nil {
			return err
		}
	}
	return nil
}

// findLinuxNode recursively locates one node by its exact cleaned path.
func findLinuxNode(node *linuxBlockDevice, wanted string) *linuxBlockDevice {
	if node.Path.Present && !node.Path.Null && filepath.Clean(node.Path.Value) == wanted {
		return node
	}
	for index := range node.Children {
		if found := findLinuxNode(&node.Children[index], wanted); found != nil {
			return found
		}
	}
	return nil
}

// linuxDevice converts one lsblk node and recursively aggregates its mounted children.
func linuxDevice(node linuxBlockDevice) (Device, error) {
	if !node.Path.Present || node.Path.Null || !filepath.IsAbs(node.Path.Value) {
		return Device{}, errors.New("lsblk device omitted an absolute path")
	}
	if !node.Type.Present || node.Type.Null || node.Type.Value == "" {
		return Device{}, fmt.Errorf("lsblk device %s omitted its type", node.Path.Value)
	}
	if !node.Size.Present || node.Size.Value == 0 {
		return Device{}, fmt.Errorf("lsblk device %s omitted a positive size", node.Path.Value)
	}
	if !node.Removable.Present || !node.ReadOnly.Present || !node.Hotplug.Present {
		return Device{}, fmt.Errorf("lsblk device %s omitted a safety boolean", node.Path.Value)
	}
	if !node.Transport.Present {
		return Device{}, fmt.Errorf("lsblk device %s omitted its transport", node.Path.Value)
	}
	if !node.MajorMinor.Present || node.MajorMinor.Null || !validMajorMinor(strings.TrimSpace(node.MajorMinor.Value)) {
		return Device{}, fmt.Errorf("lsblk device %s omitted a valid major:minor identity", node.Path.Value)
	}
	if !node.MountPoints.Present {
		return Device{}, fmt.Errorf("lsblk device %s omitted mountpoints", node.Path.Value)
	}
	if !node.LogicalBlockSize.Present || !node.PhysicalBlockSize.Present {
		return Device{}, fmt.Errorf("lsblk device %s omitted its block sizes", node.Path.Value)
	}
	path := filepath.Clean(node.Path.Value)
	name := textValue(node.Model)
	if name == "" {
		name = filepath.Base(path)
	}
	// Filesystem UUID and major:minor are intentionally excluded from StableID:
	// the former changes on write and the latter can be reused after hot-plug.
	stableID := firstText(node.WWN, node.Serial)
	device := Device{
		Path: path, RawPath: path, StableID: stableID,
		MajorMinor: textValue(node.MajorMinor), Name: name,
		Vendor: textValue(node.Vendor), Model: textValue(node.Model),
		Serial: textValue(node.Serial), WWN: textValue(node.WWN),
		Bus: strings.ToLower(textValue(node.Transport)), SizeBytes: node.Size.Value,
		LogicalBlockSize:  node.LogicalBlockSize.Value,
		PhysicalBlockSize: node.PhysicalBlockSize.Value,
		WholeDisk:         node.Type.Value == "disk" && textValue(node.ParentKernelName) == "",
		External:          node.Hotplug.Value, Removable: node.Removable.Value,
		USB: strings.EqualFold(textValue(node.Transport), "usb"), ReadOnly: node.ReadOnly.Value,
	}
	if err := collectLinuxUsage(node, &device, true); err != nil {
		return Device{}, err
	}
	return device, nil
}

// collectLinuxUsage appends mounts and conservatively marks swap or mapped
// descendants as active non-mount consumers of the whole disk.
func collectLinuxUsage(node linuxBlockDevice, device *Device, root bool) error {
	path := textValue(node.Path)
	if path == "" || !filepath.IsAbs(path) {
		return errors.New("lsblk descendant omitted an absolute path")
	}
	nodeType := strings.ToLower(textValue(node.Type))
	if nodeType == "" {
		return fmt.Errorf("lsblk device %s omitted its type", path)
	}
	if !node.MountPoints.Present {
		return fmt.Errorf("lsblk device %s omitted mountpoints", path)
	}
	if !node.ReadOnly.Present {
		return fmt.Errorf("lsblk device %s omitted its read-only classification", path)
	}
	if !node.Filesystem.Present {
		return fmt.Errorf("lsblk device %s omitted its filesystem classification", path)
	}
	if !root && nodeType != "part" {
		device.InUse = true
	}
	if strings.EqualFold(textValue(node.Filesystem), "swap") {
		device.InUse = true
	}
	for _, point := range node.MountPoints.Values {
		if strings.EqualFold(strings.TrimSpace(point), "[SWAP]") {
			device.InUse = true
			continue
		}
		mount := Mount{
			Device: path, Point: point, Filesystem: textValue(node.Filesystem),
			Label: textValue(node.Label), ReadOnly: node.ReadOnly.Value,
		}
		device.Mounts = append(device.Mounts, mount)
		if isSystemMountPoint(point) {
			device.System = true
		}
	}
	for _, child := range node.Children {
		if err := collectLinuxUsage(child, device, false); err != nil {
			return err
		}
	}
	return nil
}

// textValue returns a present non-null optional string or an empty value.
func textValue(value optionalString) string {
	if !value.Present || value.Null {
		return ""
	}
	return strings.TrimSpace(value.Value)
}

// firstText returns the first non-empty optional string in preference order.
func firstText(values ...optionalString) string {
	for _, value := range values {
		if text := textValue(value); text != "" {
			return text
		}
	}
	return ""
}
