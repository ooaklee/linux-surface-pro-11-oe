package media

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// darwinListDocument models diskutil's device-list plist after JSON conversion.
type darwinListDocument struct {
	// AllDisks contains every identifier included by the requested diskutil scope.
	AllDisks []string `json:"AllDisks"`
	// WholeDisks contains whole identifiers on diskutil versions that emit this key.
	WholeDisks []string `json:"WholeDisks"`
	// AllDisksAndPartitions contains the hierarchical inventory when available.
	AllDisksAndPartitions []darwinListNode `json:"AllDisksAndPartitions"`
}

// darwinListNode models a diskutil list node and its common nested collections.
type darwinListNode struct {
	// DeviceIdentifier is the short diskutil identifier without a /dev prefix.
	DeviceIdentifier string `json:"DeviceIdentifier"`
	// Partitions contains ordinary child partitions.
	Partitions []darwinListNode `json:"Partitions"`
	// APFSVolumes contains logical volumes reported below an APFS container.
	APFSVolumes []darwinListNode `json:"APFSVolumes"`
	// APFSPhysicalStores contains stores referenced by an APFS container.
	APFSPhysicalStores []darwinPhysicalStore `json:"APFSPhysicalStores"`
}

// darwinPhysicalStore identifies one block object backing an APFS container.
type darwinPhysicalStore struct {
	// DeviceIdentifier is the current diskutil identifier of the backing store.
	DeviceIdentifier string `json:"DeviceIdentifier"`
	// APFSPhysicalStore is a legacy alternate identifier of the backing store.
	APFSPhysicalStore string `json:"APFSPhysicalStore"`
}

// identifier returns the first supported diskutil physical-store identifier.
func (store darwinPhysicalStore) identifier() string {
	return firstNonEmpty(store.DeviceIdentifier, store.APFSPhysicalStore)
}

// darwinInfo models safety and identity fields from diskutil info.
type darwinInfo struct {
	// DeviceIdentifier is the short diskutil identifier.
	DeviceIdentifier string `json:"DeviceIdentifier"`
	// DeviceNode is the ordinary /dev path.
	DeviceNode string `json:"DeviceNode"`
	// ParentWholeDisk identifies the parent whole disk on newer macOS versions.
	ParentWholeDisk string `json:"ParentWholeDisk"`
	// PartOfWhole identifies the parent whole disk on older macOS versions.
	PartOfWhole string `json:"PartOfWhole"`
	// Whole is diskutil's common whole-device classification.
	Whole *bool `json:"Whole"`
	// WholeDisk is an alternate whole-device classification emitted by some versions.
	WholeDisk *bool `json:"WholeDisk"`
	// Internal reports whether macOS considers the media internal.
	Internal *bool `json:"Internal"`
	// RemovableMedia reports whether the underlying media is removable.
	RemovableMedia *bool `json:"RemovableMedia"`
	// Removable is an alternate removable-media field emitted by some versions.
	Removable *bool `json:"Removable"`
	// Writable reports whether the selected disk object permits writes.
	Writable *bool `json:"Writable"`
	// WritableMedia reports whether the underlying media permits writes.
	WritableMedia *bool `json:"WritableMedia"`
	// ReadOnlyMedia reports an explicit whole-media read-only state.
	ReadOnlyMedia *bool `json:"ReadOnlyMedia"`
	// ReadOnlyVolume reports an explicit volume read-only state.
	ReadOnlyVolume *bool `json:"ReadOnlyVolume"`
	// Mounted reports whether this particular disk object is mounted.
	Mounted *bool `json:"Mounted"`
	// MountPoint contains the mounted directory or an empty value.
	MountPoint *string `json:"MountPoint"`
	// BusProtocol names the physical or virtual transport.
	BusProtocol *string `json:"BusProtocol"`
	// VirtualOrPhysical distinguishes physical media from disk images and mappings.
	VirtualOrPhysical *string `json:"VirtualOrPhysical"`
	// TotalSize is the complete object size in bytes.
	TotalSize *uint64 `json:"TotalSize"`
	// DiskSize is an alternate complete size field.
	DiskSize *uint64 `json:"DiskSize"`
	// DeviceBlockSize is the logical block size in bytes.
	DeviceBlockSize *uint64 `json:"DeviceBlockSize"`
	// PhysicalBlockSize is the physical block size in bytes when exposed.
	PhysicalBlockSize *uint64 `json:"PhysicalBlockSize"`
	// MediaName is the platform's human-readable media name.
	MediaName string `json:"MediaName"`
	// VolumeName is the mounted volume's human-readable label.
	VolumeName string `json:"VolumeName"`
	// FilesystemName is the mounted filesystem's reported name.
	FilesystemName string `json:"FilesystemName"`
	// FilesystemType is an alternate filesystem type field.
	FilesystemType string `json:"FilesystemType"`
	// DeviceTreePath is the strongest hardware topology path exposed by diskutil.
	DeviceTreePath string `json:"DeviceTreePath"`
	// DiskUUID is a content or partition-layout identifier retained only for
	// decoding; it is not stable identity across a raw image write.
	DiskUUID string `json:"DiskUUID"`
	// MediaUUID is IOKit's persistent media identifier when one is available.
	MediaUUID string `json:"MediaUUID"`
	// VolumeUUID is a filesystem identifier retained only for decoding; it is not
	// stable identity across a raw image write.
	VolumeUUID string `json:"VolumeUUID"`
	// APFSPhysicalStores identifies every store backing an APFS container.
	APFSPhysicalStores []darwinPhysicalStore `json:"APFSPhysicalStores"`
}

// darwinInventory contains converted physical targets and every inspected graph node.
type darwinInventory struct {
	// PhysicalIDs is the fail-closed candidate set from `diskutil list physical`.
	PhysicalIDs []string
	// Infos maps every observed identifier to fresh diskutil information.
	Infos map[string]darwinInfo
}

// listDarwin returns physical whole disks enriched with descendant mount evidence.
func (backend *systemBackend) listDarwin(ctx context.Context) ([]Device, error) {
	inventory, err := backend.captureDarwin(ctx)
	if err != nil {
		return nil, err
	}
	return inventory.devices()
}

// inspectDarwin takes a complete fresh graph and resolves one canonical device path.
func (backend *systemBackend) inspectDarwin(ctx context.Context, path string) (Device, error) {
	inventory, err := backend.captureDarwin(ctx)
	if err != nil {
		return Device{}, err
	}
	devices, err := inventory.devices()
	if err != nil {
		return Device{}, err
	}
	wanted := filepath.Clean(path)
	for _, device := range devices {
		if device.Path == wanted {
			return device, nil
		}
	}
	return Device{}, fmt.Errorf("Darwin physical whole device %s was not found", wanted)
}

// captureDarwin acquires physical membership and the complete backing graph.
func (backend *systemBackend) captureDarwin(ctx context.Context) (darwinInventory, error) {
	physicalJSON, err := backend.captureDarwinJSON(ctx, "list", "-plist", "physical")
	if err != nil {
		return darwinInventory{}, err
	}
	allJSON, err := backend.captureDarwinJSON(ctx, "list", "-plist")
	if err != nil {
		return darwinInventory{}, err
	}
	var physicalDocument, allDocument darwinListDocument
	if err := json.Unmarshal(physicalJSON, &physicalDocument); err != nil {
		return darwinInventory{}, fmt.Errorf("decode Darwin physical-device list: %w", err)
	}
	if err := json.Unmarshal(allJSON, &allDocument); err != nil {
		return darwinInventory{}, fmt.Errorf("decode Darwin complete-device list: %w", err)
	}
	physicalIDs := wholeDarwinIDs(physicalDocument)
	if len(physicalIDs) == 0 {
		return darwinInventory{}, errors.New("Darwin physical-device list contained no whole disks")
	}
	allIDs := allDarwinIDs(allDocument)
	storeRelations := darwinStoreRelations(allDocument)
	for _, identifier := range physicalIDs {
		allIDs[identifier] = true
	}
	identifiers := make([]string, 0, len(allIDs))
	for identifier := range allIDs {
		identifiers = append(identifiers, identifier)
	}
	sort.Strings(identifiers)
	infos := make(map[string]darwinInfo, len(identifiers))
	for _, identifier := range identifiers {
		infoJSON, err := backend.captureDarwinJSON(ctx, "info", "-plist", "/dev/"+identifier)
		if err != nil {
			return darwinInventory{}, fmt.Errorf("inspect Darwin device %s: %w", identifier, err)
		}
		var info darwinInfo
		if err := json.Unmarshal(infoJSON, &info); err != nil {
			return darwinInventory{}, fmt.Errorf("decode Darwin device %s: %w", identifier, err)
		}
		if info.DeviceIdentifier == "" {
			return darwinInventory{}, fmt.Errorf("Darwin device %s omitted DeviceIdentifier", identifier)
		}
		if len(info.APFSPhysicalStores) == 0 {
			info.APFSPhysicalStores = append([]darwinPhysicalStore(nil), storeRelations[info.DeviceIdentifier]...)
		}
		infos[info.DeviceIdentifier] = info
	}
	return darwinInventory{PhysicalIDs: physicalIDs, Infos: infos}, nil
}

// darwinStoreRelations indexes APFS store links preserved only in list output.
func darwinStoreRelations(document darwinListDocument) map[string][]darwinPhysicalStore {
	relations := make(map[string][]darwinPhysicalStore)
	for _, node := range document.AllDisksAndPartitions {
		collectDarwinStoreRelations(node, relations)
	}
	return relations
}

// collectDarwinStoreRelations recursively records APFS backing links by container.
func collectDarwinStoreRelations(node darwinListNode, relations map[string][]darwinPhysicalStore) {
	if node.DeviceIdentifier != "" && len(node.APFSPhysicalStores) > 0 {
		relations[node.DeviceIdentifier] = append(
			[]darwinPhysicalStore(nil), node.APFSPhysicalStores...,
		)
	}
	for _, child := range node.Partitions {
		collectDarwinStoreRelations(child, relations)
	}
	for _, child := range node.APFSVolumes {
		collectDarwinStoreRelations(child, relations)
	}
}

// captureDarwinJSON converts one diskutil plist to JSON through plutil without a shell.
func (backend *systemBackend) captureDarwinJSON(ctx context.Context, args ...string) ([]byte, error) {
	plist, err := backend.runner.Capture(ctx, platform.Command{Name: "diskutil", Args: args})
	if err != nil {
		return nil, fmt.Errorf("run diskutil %s: %w", strings.Join(args, " "), err)
	}
	converted, err := backend.runner.Capture(ctx, platform.Command{
		Name: "plutil", Args: []string{"-convert", "json", "-o", "-", "--", "-"},
		Stdin: bytes.NewReader(plist),
	})
	if err != nil {
		return nil, fmt.Errorf("convert diskutil plist to JSON: %w", err)
	}
	return converted, nil
}

// wholeDarwinIDs extracts and sorts whole identifiers from a physical-only list.
func wholeDarwinIDs(document darwinListDocument) []string {
	seen := make(map[string]bool)
	for _, identifier := range document.WholeDisks {
		if identifier != "" {
			seen[identifier] = true
		}
	}
	for _, node := range document.AllDisksAndPartitions {
		if node.DeviceIdentifier != "" {
			seen[node.DeviceIdentifier] = true
		}
	}
	if len(seen) == 0 {
		for _, identifier := range document.AllDisks {
			if identifier != "" {
				seen[identifier] = true
			}
		}
	}
	result := make([]string, 0, len(seen))
	for identifier := range seen {
		result = append(result, identifier)
	}
	sort.Strings(result)
	return result
}

// allDarwinIDs recursively collects every object needed to resolve backing media.
func allDarwinIDs(document darwinListDocument) map[string]bool {
	seen := make(map[string]bool)
	for _, identifier := range document.AllDisks {
		if identifier != "" {
			seen[identifier] = true
		}
	}
	for _, node := range document.AllDisksAndPartitions {
		collectDarwinNodeIDs(node, seen)
	}
	return seen
}

// collectDarwinNodeIDs recursively adds one list node and its graph references.
func collectDarwinNodeIDs(node darwinListNode, seen map[string]bool) {
	if node.DeviceIdentifier != "" {
		seen[node.DeviceIdentifier] = true
	}
	for _, store := range node.APFSPhysicalStores {
		if identifier := store.identifier(); identifier != "" {
			seen[identifier] = true
		}
	}
	for _, child := range node.Partitions {
		collectDarwinNodeIDs(child, seen)
	}
	for _, child := range node.APFSVolumes {
		collectDarwinNodeIDs(child, seen)
	}
}

// devices converts every physical candidate and associates mounted descendants.
func (inventory darwinInventory) devices() ([]Device, error) {
	mounts := make(map[string][]Mount, len(inventory.PhysicalIDs))
	system := make(map[string]bool, len(inventory.PhysicalIDs))
	physical := make(map[string]bool, len(inventory.PhysicalIDs))
	for _, identifier := range inventory.PhysicalIDs {
		physical[identifier] = true
	}
	for identifier, info := range inventory.Infos {
		point, err := darwinMountPoint(info)
		if err != nil {
			return nil, err
		}
		if point == "" {
			continue
		}
		backing, err := inventory.backingPhysicalDisks(identifier, make(map[string]bool))
		if err != nil {
			return nil, err
		}
		if len(backing) == 0 {
			if strings.EqualFold(stringValue(info.VirtualOrPhysical), "Virtual") {
				continue
			}
			return nil, fmt.Errorf(
				"could not resolve the physical disk backing mounted Darwin device %s at %s",
				identifier,
				point,
			)
		}
		for _, target := range backing {
			if !physical[target] {
				continue
			}
			mounts[target] = append(mounts[target], Mount{
				Device: darwinDeviceNode(info), Point: point,
				Filesystem: firstNonEmpty(info.FilesystemName, info.FilesystemType),
				Label:      info.VolumeName, ReadOnly: darwinReadOnly(info),
			})
			if isSystemMountPoint(point) {
				system[target] = true
			}
		}
	}

	devices := make([]Device, 0, len(inventory.PhysicalIDs))
	for _, identifier := range inventory.PhysicalIDs {
		info, exists := inventory.Infos[identifier]
		if !exists {
			return nil, fmt.Errorf("Darwin physical device %s disappeared during inspection", identifier)
		}
		device, err := darwinDevice(info)
		if err != nil {
			return nil, err
		}
		device.Mounts = mounts[identifier]
		device.System = system[identifier]
		devices = append(devices, device)
	}
	return devices, nil
}

// backingPhysicalDisks resolves one partition or APFS object to whole physical disks.
func (inventory darwinInventory) backingPhysicalDisks(identifier string, visiting map[string]bool) ([]string, error) {
	if visiting[identifier] {
		return nil, fmt.Errorf("cycle in Darwin backing-device graph at %s", identifier)
	}
	info, exists := inventory.Infos[identifier]
	if !exists {
		return nil, fmt.Errorf("Darwin backing-device graph references missing %s", identifier)
	}
	visiting[identifier] = true
	defer delete(visiting, identifier)

	if len(info.APFSPhysicalStores) > 0 {
		seen := make(map[string]bool)
		var result []string
		for _, store := range info.APFSPhysicalStores {
			storeIdentifier := store.identifier()
			if storeIdentifier == "" {
				return nil, fmt.Errorf("Darwin device %s has an unnamed APFS physical store", identifier)
			}
			backing, err := inventory.backingPhysicalDisks(storeIdentifier, visiting)
			if err != nil {
				return nil, err
			}
			for _, candidate := range backing {
				if !seen[candidate] {
					seen[candidate] = true
					result = append(result, candidate)
				}
			}
		}
		sort.Strings(result)
		return result, nil
	}
	parent := firstNonEmpty(info.ParentWholeDisk, info.PartOfWhole)
	if parent != "" && parent != identifier {
		return inventory.backingPhysicalDisks(parent, visiting)
	}
	whole, present := darwinWhole(info)
	if present && whole && inventory.isPhysicalID(identifier) {
		return []string{identifier}, nil
	}
	return nil, nil
}

// isPhysicalID reports authoritative membership in diskutil's physical-only list.
func (inventory darwinInventory) isPhysicalID(identifier string) bool {
	for _, physicalID := range inventory.PhysicalIDs {
		if physicalID == identifier {
			return true
		}
	}
	return false
}

// darwinDevice converts one physical diskutil record with strict safety fields.
func darwinDevice(info darwinInfo) (Device, error) {
	whole, wholePresent := darwinWhole(info)
	removable, removablePresent := firstBool(info.RemovableMedia, info.Removable)
	writable, writablePresent := firstBool(info.WritableMedia, info.Writable)
	if !wholePresent || info.Internal == nil || !removablePresent || !writablePresent {
		return Device{}, fmt.Errorf("Darwin device %s omitted a safety classification", info.DeviceIdentifier)
	}
	if info.BusProtocol == nil || info.TotalSize == nil && info.DiskSize == nil {
		return Device{}, fmt.Errorf("Darwin device %s omitted transport or size", info.DeviceIdentifier)
	}
	if strings.EqualFold(stringValue(info.VirtualOrPhysical), "Virtual") {
		return Device{}, fmt.Errorf("Darwin device %s is explicitly virtual despite physical-list membership", info.DeviceIdentifier)
	}
	size := uint64(0)
	if info.TotalSize != nil {
		size = *info.TotalSize
	} else if info.DiskSize != nil {
		size = *info.DiskSize
	}
	if size == 0 {
		return Device{}, fmt.Errorf("Darwin device %s has no positive size", info.DeviceIdentifier)
	}
	logical := uint64(0)
	if info.DeviceBlockSize != nil {
		logical = *info.DeviceBlockSize
	}
	physical := logical
	if info.PhysicalBlockSize != nil {
		physical = *info.PhysicalBlockSize
	}
	path := darwinDeviceNode(info)
	bus := strings.ToLower(stringValue(info.BusProtocol))
	name := firstNonEmpty(info.MediaName, info.VolumeName, info.DeviceIdentifier)
	return Device{
		Path: path, RawPath: "/dev/r" + strings.TrimPrefix(path, "/dev/"),
		HardwarePath: info.DeviceTreePath,
		StableID:     strings.TrimSpace(info.MediaUUID),
		Name:         name, Model: info.MediaName, Bus: bus, SizeBytes: size,
		LogicalBlockSize: logical, PhysicalBlockSize: physical,
		WholeDisk: whole, External: !*info.Internal, Removable: removable,
		USB:      strings.EqualFold(stringValue(info.BusProtocol), "USB"),
		ReadOnly: !writable || darwinReadOnly(info),
	}, nil
}

// darwinDeviceNode returns an explicit node or derives it from the strict identifier.
func darwinDeviceNode(info darwinInfo) string {
	if strings.HasPrefix(info.DeviceNode, "/dev/") {
		return filepath.Clean(info.DeviceNode)
	}
	return "/dev/" + info.DeviceIdentifier
}

// darwinMountPoint validates diskutil's mounted state and returns its absolute path.
func darwinMountPoint(info darwinInfo) (string, error) {
	point := ""
	if info.MountPoint != nil {
		point = strings.TrimSpace(*info.MountPoint)
	}
	if info.Mounted != nil && !*info.Mounted {
		if point != "" {
			return "", fmt.Errorf("Darwin device %s reported a mount point while unmounted", info.DeviceIdentifier)
		}
		return "", nil
	}
	if info.Mounted != nil && *info.Mounted && point == "" {
		return "", fmt.Errorf("Darwin device %s omitted a mount point while mounted", info.DeviceIdentifier)
	}
	if point == "" {
		return "", nil
	}
	if !filepath.IsAbs(point) {
		return "", fmt.Errorf("Darwin device %s omitted an absolute mount point while mounted", info.DeviceIdentifier)
	}
	return point, nil
}

// darwinReadOnly combines every explicit media and volume read-only signal.
func darwinReadOnly(info darwinInfo) bool {
	return info.ReadOnlyMedia != nil && *info.ReadOnlyMedia ||
		info.ReadOnlyVolume != nil && *info.ReadOnlyVolume ||
		info.Writable != nil && !*info.Writable ||
		info.WritableMedia != nil && !*info.WritableMedia
}

// darwinWhole returns the preferred whole-device field and whether it was present.
func darwinWhole(info darwinInfo) (bool, bool) {
	return firstBool(info.Whole, info.WholeDisk)
}

// firstBool returns the first present boolean and a presence flag.
func firstBool(values ...*bool) (bool, bool) {
	for _, value := range values {
		if value != nil {
			return *value, true
		}
	}
	return false, false
}

// stringValue returns a pointed-to string or an empty value.
func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return strings.TrimSpace(*value)
}

// firstNonEmpty returns the first trimmed non-empty string.
func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}
