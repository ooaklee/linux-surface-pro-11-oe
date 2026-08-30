package handoff

import (
	"context"
	"errors"
	"fmt"
	"os"
)

// ApplicationMaterial is an opaque, freshly revalidated private store entry
// supplied only to the installed-system application domain.
type ApplicationMaterial struct {
	// identifier is the exact manifest content address.
	identifier string
	// entryPath is the resolved, validated private store child.
	entryPath string
	// closedSetSHA256 binds the complete current stored inventory.
	closedSetSHA256 string
	// contract contains private values and must never be formatted or serialised.
	contract Contract
}

// String returns a redacted opaque-handle summary without private contract fields.
func (material ApplicationMaterial) String() string {
	return fmt.Sprintf("private Windows hand-off application material %s", material.identifier)
}

// GoString returns the same redacted opaque-handle summary for diagnostics.
func (material ApplicationMaterial) GoString() string {
	return material.String()
}

// RevalidateForApplication performs the complete private-store audit and
// returns an opaque handle without exposing private contract fields in output.
func RevalidateForApplication(ctx context.Context, storeRoot, identifier string) (ApplicationMaterial, error) {
	if ctx == nil {
		return ApplicationMaterial{}, errors.New("revalidate Windows hand-off for application: context is nil")
	}
	if err := ctx.Err(); err != nil {
		return ApplicationMaterial{}, err
	}
	resolvedStoreRoot, err := resolveStoreRoot(storeRoot)
	if err != nil {
		return ApplicationMaterial{}, err
	}
	entryPath, err := directStoreChild(resolvedStoreRoot, identifier)
	if err != nil {
		return ApplicationMaterial{}, err
	}
	validated, err := validateStoredEntry(ctx, entryPath, identifier)
	if err != nil {
		return ApplicationMaterial{}, fmt.Errorf("revalidate selected private Windows hand-off: %w", err)
	}
	return ApplicationMaterial{
		identifier:      identifier,
		entryPath:       entryPath,
		closedSetSHA256: digestClosedSet(identifier, validated.auditedStoreEntry),
		contract:        clonePrivateContract(validated.contract),
	}, nil
}

// ID returns the public content address of the revalidated material.
func (material ApplicationMaterial) ID() string {
	return material.identifier
}

// ClosedSetSHA256 returns the revalidation checkpoint without revealing any
// private payload bytes or hardware values.
func (material ApplicationMaterial) ClosedSetSHA256() string {
	return material.closedSetSHA256
}

// Summary returns only the contract's deliberately redacted public view.
func (material ApplicationMaterial) Summary() Summary {
	return material.contract.Summary()
}

// PrivateContract returns a defensive copy for the private application domain.
// Callers must never format, log, serialise, or return this value.
func (material ApplicationMaterial) PrivateContract() Contract {
	return clonePrivateContract(material.contract)
}

// OpenFirmware opens one compiled firmware payload without following symbolic
// links and rechecks its current size before the caller copies and rehashes it.
func (material ApplicationMaterial) OpenFirmware(ctx context.Context, identifier string) (*os.File, FirmwareFileRecord, error) {
	if ctx == nil {
		return nil, FirmwareFileRecord{}, errors.New("open private hand-off firmware: context is nil")
	}
	if err := ctx.Err(); err != nil {
		return nil, FirmwareFileRecord{}, err
	}
	var selected *FirmwareFileRecord
	for index := range material.contract.PlatformFirmware.Files {
		record := &material.contract.PlatformFirmware.Files[index]
		if record.ID == identifier {
			selected = record
			break
		}
	}
	if selected == nil {
		return nil, FirmwareFileRecord{}, errors.New("requested firmware is not present in the revalidated hand-off")
	}
	file, err := openRegularNoFollow(material.entryPath, selected.PayloadPath)
	if err != nil {
		return nil, FirmwareFileRecord{}, fmt.Errorf("open revalidated private firmware %s: %w", selected.ID, err)
	}
	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, FirmwareFileRecord{}, fmt.Errorf("inspect revalidated private firmware %s: %w", selected.ID, err)
	}
	if !info.Mode().IsRegular() || info.Size() != selected.Size {
		_ = file.Close()
		return nil, FirmwareFileRecord{}, fmt.Errorf("revalidated private firmware %s changed before application", selected.ID)
	}
	return file, *selected, nil
}

// clonePrivateContract copies every mutable union member while retaining its
// private classification and redacting behaviour.
func clonePrivateContract(contract Contract) Contract {
	cloned := contract
	cloned.PlatformFirmware.Files = append([]FirmwareFileRecord(nil), contract.PlatformFirmware.Files...)
	if contract.PlatformFirmware.Reason != nil {
		reason := *contract.PlatformFirmware.Reason
		cloned.PlatformFirmware.Reason = &reason
	}
	if contract.BluetoothPublicAddress.Reason != nil {
		reason := *contract.BluetoothPublicAddress.Reason
		cloned.BluetoothPublicAddress.Reason = &reason
	}
	if contract.BluetoothPublicAddress.Address != nil {
		address := *contract.BluetoothPublicAddress.Address
		cloned.BluetoothPublicAddress.Address = &address
	}
	if contract.BluetoothPublicAddress.Source != nil {
		source := *contract.BluetoothPublicAddress.Source
		cloned.BluetoothPublicAddress.Source = &source
	}
	return cloned
}
