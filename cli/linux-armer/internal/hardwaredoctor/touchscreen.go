package hardwaredoctor

import (
	"context"
	"errors"
	"io/fs"
	"path"
	"strings"
	"time"
)

const (
	// maximumSPIDevices bounds the live SPI device inventory.
	maximumSPIDevices = 256
	// maximumTouchscreenBusValueBytes bounds one SPI identity property.
	maximumTouchscreenBusValueBytes int64 = 4096
	// maximumInputDevicesBytes bounds the procfs input inventory.
	maximumInputDevicesBytes int64 = 128 << 10
	// maximumTouchscreenTreeDepth bounds traversal below the QSPI controller.
	maximumTouchscreenTreeDepth = 4
)

// touchscreenFirmwarePaths is the closed set of supported QUP firmware locations.
var touchscreenFirmwarePaths = []string{
	"/lib/firmware/qcom/x1e80100/qupv3fw.elf.zst",
	"/lib/firmware/qcom/x1e80100/qupv3fw.elf.xz",
	"/lib/firmware/qcom/x1e80100/qupv3fw.elf",
}

// touchscreenDeviceTreeRoots lists the standard loaded device-tree views.
var touchscreenDeviceTreeRoots = []string{
	"/sys/firmware/devicetree/base",
	"/proc/device-tree",
}

// touchscreenDeviceTreeState aggregates loaded topology without retaining paths.
type touchscreenDeviceTreeState struct {
	// controllerPresent records discovery of the fixed QSPI controller node.
	controllerPresent bool
	// controllerEnabled records the standard enabled status value.
	controllerEnabled bool
	// clientPresent records an exact microsoft,mshw0485 compatible child.
	clientPresent bool
	// topologyUnavailable records incomplete bounded controller discovery.
	topologyUnavailable bool
	// statusUnavailable records an unreadable controller status property.
	statusUnavailable bool
	// clientUnavailable records incomplete bounded compatible discovery.
	clientUnavailable bool
}

// touchscreenSPIState aggregates SPI client registration without retaining names.
type touchscreenSPIState struct {
	// present records an MSHW0485 modalias or uevent identity.
	present bool
	// incomplete records an unreadable or unsafe inventory entry.
	incomplete bool
	// unavailable records failure to inspect the SPI inventory itself.
	unavailable bool
}

// inspectTouchscreen reports the maintained in-tree stack without checking
// retired override modules, module parameters, or initramfs override paths.
func (doctor *Doctor) inspectTouchscreen(ctx context.Context, probeTimeout time.Duration) ([]Check, error) {
	checks := make([]Check, 0, 7)
	firmware, err := doctor.inspectTouchscreenFirmware(ctx)
	if err != nil {
		return nil, err
	}
	checks = append(checks, firmware)
	deviceTree, err := doctor.readTouchscreenDeviceTree(ctx)
	if err != nil {
		return nil, err
	}
	checks = append(checks, touchscreenControllerCheck(deviceTree), touchscreenClientCheck(deviceTree))
	spi, err := doctor.readTouchscreenSPI(ctx)
	if err != nil {
		return nil, err
	}
	checks = append(checks, touchscreenSPICheck(spi))
	input, err := doctor.inspectTouchscreenInput(ctx)
	if err != nil {
		return nil, err
	}
	checks = append(checks, input)
	kernelLog, err := doctor.inspectTouchscreenKernelLog(ctx, probeTimeout)
	if err != nil {
		return nil, err
	}
	checks = append(checks, kernelLog, hardwareLimitation(FeatureTouchscreen))
	return checks, nil
}

// inspectTouchscreenFirmware checks the closed QUP firmware path set read-only.
func (doctor *Doctor) inspectTouchscreenFirmware(ctx context.Context) (Check, error) {
	unavailable := false
	for _, firmwarePath := range touchscreenFirmwarePaths {
		info, err := doctor.filesystem.Stat(ctx, firmwarePath)
		if err == nil && info.Kind == PathRegular {
			return Check{
				ID:       "touchscreen-qup-firmware",
				Feature:  FeatureTouchscreen,
				Evidence: EvidenceStatic,
				State:    StatePass,
				Required: true,
				Detail:   "the supported QUP firmware is present",
			}, nil
		}
		if err == nil {
			return Check{
				ID:          "touchscreen-qup-firmware",
				Feature:     FeatureTouchscreen,
				Evidence:    EvidenceStatic,
				State:       StateFail,
				Required:    true,
				Detail:      "a QUP firmware path exists but is not a regular file",
				Remediation: "restore the distribution's Qualcomm X1E firmware package, then rerun the diagnostic",
			}, nil
		}
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return Check{}, err
		}
		if !errors.Is(err, fs.ErrNotExist) {
			unavailable = true
		}
	}
	if unavailable {
		return Check{
			ID:          "touchscreen-qup-firmware",
			Feature:     FeatureTouchscreen,
			Evidence:    EvidenceStatic,
			State:       StateUnavailable,
			Required:    true,
			Detail:      "QUP firmware presence could not be inspected safely",
			Remediation: "run the static userspace doctor against the same system root",
		}, nil
	}
	return Check{
		ID:          "touchscreen-qup-firmware",
		Feature:     FeatureTouchscreen,
		Evidence:    EvidenceStatic,
		State:       StateFail,
		Required:    true,
		Detail:      "the supported QUP firmware is absent",
		Remediation: "install the distribution's Qualcomm X1E firmware package, then rerun the diagnostic",
	}, nil
}

// readTouchscreenDeviceTree discovers the loaded controller and client within fixed bounds.
func (doctor *Doctor) readTouchscreenDeviceTree(ctx context.Context) (touchscreenDeviceTreeState, error) {
	var incomplete touchscreenDeviceTreeState
	rootObserved := false
	completeRootObserved := false
	for _, root := range touchscreenDeviceTreeRoots {
		state, err := doctor.walkTouchscreenDeviceTree(ctx, root)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				return touchscreenDeviceTreeState{}, err
			}
			incomplete.topologyUnavailable = true
			continue
		}
		rootObserved = true
		if !state.topologyUnavailable {
			completeRootObserved = true
		}
		if state.controllerPresent && !state.statusUnavailable && !state.clientUnavailable {
			return state, nil
		}
		if state.controllerPresent {
			incomplete = state
		}
	}
	if incomplete.controllerPresent {
		return incomplete, nil
	}
	if !rootObserved || !completeRootObserved {
		incomplete.topologyUnavailable = true
	}
	return incomplete, nil
}

// walkTouchscreenDeviceTree performs one bounded breadth-first controller search.
func (doctor *Doctor) walkTouchscreenDeviceTree(ctx context.Context, root string) (touchscreenDeviceTreeState, error) {
	queue := []deviceTreeDirectory{{path: root, depth: 0}}
	visited := 0
	state := touchscreenDeviceTreeState{}
	for len(queue) != 0 {
		if err := ctx.Err(); err != nil {
			return touchscreenDeviceTreeState{}, err
		}
		current := queue[0]
		queue = queue[1:]
		entries, err := doctor.filesystem.ReadDir(ctx, current.path, maximumDeviceTreeChildren)
		if err != nil {
			if current.depth == 0 {
				return touchscreenDeviceTreeState{}, err
			}
			state.topologyUnavailable = true
			continue
		}
		visited += len(entries)
		if visited > maximumDeviceTreeEntries {
			state.topologyUnavailable = true
			return state, nil
		}
		for _, entry := range entries {
			if !safeLeaf(entry.Name) || entry.Kind != PathDirectory {
				continue
			}
			child := path.Join(current.path, entry.Name)
			if entry.Name == "spi@a88000" {
				return doctor.inspectTouchscreenController(ctx, child)
			}
			if current.depth < maximumDeviceTreeDepth {
				queue = append(queue, deviceTreeDirectory{path: child, depth: current.depth + 1})
			}
		}
	}
	return state, nil
}

// inspectTouchscreenController classifies one fixed controller and its compatible descendants.
func (doctor *Doctor) inspectTouchscreenController(ctx context.Context, controllerPath string) (touchscreenDeviceTreeState, error) {
	state := touchscreenDeviceTreeState{controllerPresent: true, controllerEnabled: true}
	status, err := doctor.filesystem.ReadFile(ctx, path.Join(controllerPath, "status"), maximumSysfsValueBytes)
	if err == nil {
		value := strings.ToLower(strings.Trim(strings.TrimSpace(string(status)), "\x00"))
		state.controllerEnabled = value == "" || value == "ok" || value == "okay"
	} else if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return touchscreenDeviceTreeState{}, err
	} else if !errors.Is(err, fs.ErrNotExist) {
		state.statusUnavailable = true
	}
	queue := []deviceTreeDirectory{{path: controllerPath, depth: 0}}
	visited := 0
	for len(queue) != 0 {
		if err := ctx.Err(); err != nil {
			return touchscreenDeviceTreeState{}, err
		}
		current := queue[0]
		queue = queue[1:]
		entries, readErr := doctor.filesystem.ReadDir(ctx, current.path, maximumDeviceTreeChildren)
		if readErr != nil {
			state.clientUnavailable = true
			continue
		}
		visited += len(entries)
		if visited > maximumDeviceTreeEntries {
			state.clientUnavailable = true
			break
		}
		for _, entry := range entries {
			if !safeLeaf(entry.Name) || entry.Kind != PathDirectory {
				continue
			}
			child := path.Join(current.path, entry.Name)
			compatible, compatibleErr := doctor.filesystem.ReadFile(ctx, path.Join(child, "compatible"), maximumTouchscreenBusValueBytes)
			if compatibleErr == nil && containsDeviceTreeCompatible(compatible, "microsoft,mshw0485") {
				state.clientPresent = true
				return state, nil
			}
			if compatibleErr != nil && !errors.Is(compatibleErr, fs.ErrNotExist) {
				if errors.Is(compatibleErr, context.Canceled) || errors.Is(compatibleErr, context.DeadlineExceeded) {
					return touchscreenDeviceTreeState{}, compatibleErr
				}
				state.clientUnavailable = true
			}
			if current.depth < maximumTouchscreenTreeDepth {
				queue = append(queue, deviceTreeDirectory{path: child, depth: current.depth + 1})
			}
		}
	}
	return state, nil
}

// containsDeviceTreeCompatible matches one exact NUL-delimited compatible value.
func containsDeviceTreeCompatible(content []byte, wanted string) bool {
	for _, value := range strings.Split(string(content), "\x00") {
		if strings.TrimSpace(value) == wanted {
			return true
		}
	}
	return false
}

// touchscreenControllerCheck maps loaded controller topology to fixed prose.
func touchscreenControllerCheck(state touchscreenDeviceTreeState) Check {
	check := Check{ID: "touchscreen-device-tree-controller", Feature: FeatureTouchscreen, Evidence: EvidenceStatic, Required: true}
	switch {
	case state.topologyUnavailable || state.statusUnavailable:
		check.State = StateUnavailable
		check.Detail = "the loaded QSPI controller state could not be inspected safely"
	case !state.controllerPresent:
		check.State = StateFail
		check.Detail = "the loaded device tree lacks the Surface touchscreen QSPI controller"
		check.Remediation = "boot the maintained Surface device tree paired with the running kernel"
	case !state.controllerEnabled:
		check.State = StateFail
		check.Detail = "the loaded Surface touchscreen QSPI controller is disabled"
		check.Remediation = "boot the maintained Surface device tree paired with the running kernel"
	default:
		check.State = StatePass
		check.Detail = "the loaded device tree enables the Surface touchscreen QSPI controller"
	}
	return check
}

// touchscreenClientCheck maps the compatible-child result to fixed prose.
func touchscreenClientCheck(state touchscreenDeviceTreeState) Check {
	check := Check{ID: "touchscreen-device-tree-client", Feature: FeatureTouchscreen, Evidence: EvidenceStatic, Required: true}
	switch {
	case state.topologyUnavailable || state.clientUnavailable:
		check.State = StateUnavailable
		check.Detail = "the loaded touchscreen device-tree client could not be inspected safely"
	case !state.controllerPresent || !state.clientPresent:
		check.State = StateFail
		check.Detail = "the loaded QSPI controller lacks the Microsoft MSHW0485 client"
		check.Remediation = "boot the maintained Surface device tree paired with the running kernel"
	default:
		check.State = StatePass
		check.Detail = "the loaded QSPI controller contains the Microsoft MSHW0485 client"
	}
	return check
}

// readTouchscreenSPI finds the MSHW0485 client through bounded public identities.
func (doctor *Doctor) readTouchscreenSPI(ctx context.Context) (touchscreenSPIState, error) {
	entries, err := doctor.filesystem.ReadDir(ctx, "/sys/bus/spi/devices", maximumSPIDevices)
	if errors.Is(err, fs.ErrNotExist) {
		return touchscreenSPIState{}, nil
	}
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return touchscreenSPIState{}, err
		}
		return touchscreenSPIState{unavailable: true}, nil
	}
	state := touchscreenSPIState{}
	for _, entry := range entries {
		if !safeLeaf(entry.Name) {
			state.incomplete = true
			continue
		}
		base := path.Join("/sys/bus/spi/devices", entry.Name)
		matched := false
		for _, property := range []string{"modalias", "uevent"} {
			content, readErr := doctor.filesystem.ReadFile(ctx, path.Join(base, property), maximumTouchscreenBusValueBytes)
			if readErr == nil && containsTouchscreenSPIIdentity(content) {
				matched = true
				break
			}
			if readErr != nil && !errors.Is(readErr, fs.ErrNotExist) {
				if errors.Is(readErr, context.Canceled) || errors.Is(readErr, context.DeadlineExceeded) {
					return touchscreenSPIState{}, readErr
				}
				state.incomplete = true
			}
		}
		if matched {
			state.present = true
			return state, nil
		}
	}
	return state, nil
}

// containsTouchscreenSPIIdentity recognises exact supported modalias identities.
func containsTouchscreenSPIIdentity(content []byte) bool {
	lower := strings.ToLower(string(content))
	for _, identity := range []string{"microsoft,mshw0485", "spi:mshw0485", "acpi:mshw0485"} {
		for offset := 0; offset < len(lower); {
			index := strings.Index(lower[offset:], identity)
			if index < 0 {
				break
			}
			start := offset + index
			end := start + len(identity)
			validStart := start == 0 || touchscreenIdentityDelimiter(lower[start-1])
			validEnd := end == len(lower) || touchscreenIdentityDelimiter(lower[end])
			if validStart && validEnd {
				return true
			}
			offset = end
		}
	}
	return false
}

// touchscreenIdentityDelimiter accepts kernel modalias and line delimiters.
func touchscreenIdentityDelimiter(value byte) bool {
	return value == 0 || value == '\r' || value == '\n' || value == '\t' || value == ' ' || value == ':' || value == '=' || value == 'c'
}

// touchscreenSPICheck maps live bus registration to fixed prose.
func touchscreenSPICheck(state touchscreenSPIState) Check {
	check := Check{ID: "touchscreen-spi-client", Feature: FeatureTouchscreen, Evidence: EvidenceRuntime, Required: true}
	switch {
	case state.unavailable || (state.incomplete && !state.present):
		check.State = StateUnavailable
		check.Detail = "live SPI client registration could not be inspected safely"
	case !state.present:
		check.State = StateFail
		check.Detail = "the Microsoft MSHW0485 client is not registered on the live SPI bus"
		check.Remediation = "review the loaded Surface device tree and bounded current-boot kernel messages"
	default:
		check.State = StatePass
		check.Detail = "the Microsoft MSHW0485 client is registered on the live SPI bus"
	}
	return check
}

// inspectTouchscreenInput checks the fixed input-device name without retaining inventory text.
func (doctor *Doctor) inspectTouchscreenInput(ctx context.Context) (Check, error) {
	content, err := doctor.filesystem.ReadFile(ctx, "/proc/bus/input/devices", maximumInputDevicesBytes)
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return Check{}, err
		}
		state := StateUnavailable
		detail := "the live input-device inventory could not be inspected safely"
		if errors.Is(err, fs.ErrNotExist) {
			state = StateFail
			detail = "the kernel exposes no input-device inventory containing the Surface touchscreen"
		}
		return Check{ID: "touchscreen-input-device", Feature: FeatureTouchscreen, Evidence: EvidenceRuntime, State: state, Required: true, Detail: detail}, nil
	}
	for _, line := range strings.Split(string(content), "\n") {
		if strings.TrimSpace(line) == `N: Name="Microsoft Surface G6 Touch"` {
			return Check{ID: "touchscreen-input-device", Feature: FeatureTouchscreen, Evidence: EvidenceRuntime, State: StatePass, Required: true, Detail: "the kernel exposes the Microsoft Surface G6 Touch input device"}, nil
		}
	}
	return Check{
		ID:          "touchscreen-input-device",
		Feature:     FeatureTouchscreen,
		Evidence:    EvidenceRuntime,
		State:       StateFail,
		Required:    true,
		Detail:      "the Microsoft Surface G6 Touch input device is absent",
		Remediation: "review SPI registration and bounded current-boot kernel messages",
	}, nil
}

// inspectTouchscreenKernelLog uses a bounded dmesg read with a journal fallback.
func (doctor *Doctor) inspectTouchscreenKernelLog(ctx context.Context, probeTimeout time.Duration) (Check, error) {
	dmesg, dmesgOutcome, err := doctor.runProbeWithLimit(ctx, ProbeKernelLogDmesg, probeTimeout, maximumKernelLogProbeOutput)
	if err != nil {
		return Check{}, err
	}
	if dmesgOutcome == probeCompleted && dmesg.ExitCode == 0 {
		return classifyTouchscreenKernelLog(dmesg.Output), nil
	}
	journal, journalOutcome, err := doctor.runProbeWithLimit(ctx, ProbeKernelLogJournal, probeTimeout, maximumKernelLogProbeOutput)
	if err != nil {
		return Check{}, err
	}
	if journalOutcome == probeCompleted && journal.ExitCode == 0 {
		return classifyTouchscreenKernelLog(journal.Output), nil
	}
	return unavailableTouchscreenKernelLogCheck(dmesgOutcome, journalOutcome), nil
}

// unavailableTouchscreenKernelLogCheck reports bounded probe failure without raw errors.
func unavailableTouchscreenKernelLogCheck(dmesgOutcome, journalOutcome probeOutcome) Check {
	detail := "current-boot touchscreen kernel messages are unavailable to this user"
	if dmesgOutcome == probeTimedOut || journalOutcome == probeTimedOut {
		detail = "the bounded current-boot kernel-log inspection timed out"
	} else if dmesgOutcome == probeOversized || journalOutcome == probeOversized {
		detail = "the current-boot kernel log exceeded the safe inspection bound"
	}
	return Check{
		ID:          "touchscreen-kernel-runtime",
		Feature:     FeatureTouchscreen,
		Evidence:    EvidenceRuntime,
		State:       StateUnavailable,
		Required:    false,
		Detail:      detail,
		Remediation: "rerun with permission to read current-boot kernel messages; no raw log is included in the report",
	}
}

// classifyTouchscreenKernelLog maps recognised current-boot markers to redacted conclusions.
func classifyTouchscreenKernelLog(content []byte) Check {
	lower := strings.ToLower(string(content))
	check := Check{ID: "touchscreen-kernel-runtime", Feature: FeatureTouchscreen, Evidence: EvidenceRuntime}
	switch {
	case strings.Contains(lower, "geni_spi a88000.spi: invalid proto 9"):
		check.State = StateFail
		check.Required = true
		check.Detail = "the current boot rejected the Surface QSPI controller protocol"
		check.Remediation = "boot a maintained kernel containing the in-tree Surface QSPI stack"
	case strings.Contains(lower, "sync_state() pending due to a88000.spi"):
		check.State = StateFail
		check.Required = true
		check.Detail = "the current boot left device dependencies blocked by the Surface QSPI controller"
	case touchscreenFirmwareFailure(lower):
		check.State = StateFail
		check.Required = true
		check.Detail = "the current boot reports a QUP firmware loading failure"
		check.Remediation = "restore the Qualcomm X1E firmware package and inspect the next boot"
	default:
		successIndex := strings.LastIndex(lower, "touch controller initialized path=")
		failureIndex := strings.LastIndex(lower, "touch controller initialization failed")
		timeoutIndex := strings.LastIndex(lower, "ch start completion timeout")
		switch {
		case failureIndex >= 0 && failureIndex > successIndex:
			check.State = StateFail
			check.Required = true
			check.Detail = "the latest observed touchscreen controller initialisation attempt failed"
			check.Remediation = "inspect the redacted topology and SPI checks before reviewing the local kernel log"
		case successIndex >= 0:
			check.State = StatePass
			check.Required = true
			if timeoutIndex >= 0 && timeoutIndex < successIndex {
				check.State = StateWarn
				check.Required = false
				check.Detail = "the touchscreen controller initialised after an earlier GPI channel-start timeout"
			} else {
				check.Detail = "the touchscreen controller reported successful initialisation during the current boot"
			}
		case timeoutIndex >= 0:
			check.State = StateWarn
			check.Required = false
			check.Detail = "the current boot contains a GPI channel-start timeout without conclusive touchscreen attribution"
			check.Remediation = "review the local kernel log alongside the SPI and input checks"
		case strings.Contains(lower, "microsoft surface g6 touch"):
			check.State = StateWarn
			check.Required = false
			check.Detail = "the kernel log records touchscreen input registration but no final controller initialisation marker"
		default:
			check.State = StateWarn
			check.Required = false
			check.Detail = "the bounded current-boot kernel log contains no conclusive touchscreen initialisation marker"
			check.Remediation = "interpret this alongside live SPI and input registration; the doctor does not require custom out-of-tree success markers"
		}
	}
	return check
}

// touchscreenFirmwareFailure recognises only fixed QUP firmware failure phrases.
func touchscreenFirmwareFailure(lowerLog string) bool {
	for _, line := range strings.Split(lowerLog, "\n") {
		if strings.Contains(line, "a88000.spi") && strings.Contains(line, "spi master firmware load failed") {
			return true
		}
		if (strings.Contains(line, "direct firmware load") || strings.Contains(line, "failed to load")) &&
			(strings.Contains(line, "qupv3fw") || strings.Contains(line, "qup firmware")) {
			return true
		}
	}
	return false
}
