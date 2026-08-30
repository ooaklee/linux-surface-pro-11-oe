package capture

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

// compiled validation expressions recognise supported Surface kernel ABIs,
// safe media names, negotiated video fields, bytes-used reports, and emitted
// camera transport failures.
var (
	surfaceReleasePattern  = regexp.MustCompile(`^[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[0-9A-Za-z.+~]+)*-jg-[0-9A-Za-z.+~]*sp11v([0-9]+)-qcom-x1e$`)
	mediaDevicePattern     = regexp.MustCompile(`^/dev/media[0-9]+$`)
	videoDevicePattern     = regexp.MustCompile(`^/dev/video[0-9]+$`)
	subdevicePattern       = regexp.MustCompile(`^/dev/v4l-subdev[0-9]+$`)
	entityNamePattern      = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z ._:+@/-]{0,255}$`)
	widthHeightPattern     = regexp.MustCompile(`(?m)Width/Height\s*:\s*([0-9]+)/([0-9]+)`)
	pixelFormatPattern     = regexp.MustCompile(`(?m)Pixel Format\s*:\s*'([^']+)'`)
	bytesPerLinePattern    = regexp.MustCompile(`(?m)Bytes per Line\s*:\s*([0-9]+)`)
	sizeImagePattern       = regexp.MustCompile(`(?m)Size Image\s*:\s*([0-9]+)`)
	bytesUsedPattern       = regexp.MustCompile(`(?i)bytes[ _-]*used[^0-9]*([0-9]+)`)
	cameraLinePattern      = regexp.MustCompile(`(?i)camss|csid|csiphy|vfe|imx681|ccs|camera`)
	cameraViolationPattern = regexp.MustCompile(`(?i)fifo.*(?:overflow|overrun)|(?:overflow|overrun).*fifo|image[ _-]*violation|truncat(?:ed|ion)|stop.*(?:time[ _-]*out|timed out)|(?:time[ _-]*out|timed out).*stop|halt.*(?:time[ _-]*out|timed out)|(?:time[ _-]*out|timed out).*halt`)
)

// New constructs the native camera capture manager with production-safe host
// boundaries when no runner is supplied.
func New(runner Runner) *Manager {
	if runner == nil {
		runner = ExecRunner{}
	}
	manager := &Manager{Runner: runner, now: time.Now, hostOS: runtime.GOOS}
	manager.mediaDevices = func() ([]string, error) {
		devices, err := filepath.Glob("/dev/media[0-9]*")
		sort.Strings(devices)
		return devices, err
	}
	manager.runningRelease = func(ctx context.Context) (string, error) {
		commandContext, cancel := context.WithTimeout(ctx, metadataTimeout)
		defer cancel()
		content, err := manager.Runner.Capture(commandContext, Command{Name: "uname", Args: []string{"-r"}}, 4096)
		if err != nil {
			return "", err
		}
		return strings.TrimSpace(string(content)), nil
	}
	manager.modulePresent = func(module string) bool {
		info, err := os.Stat(filepath.Join("/sys/module", module))
		return err == nil && info.IsDir()
	}
	manager.validateDevice = validateCharacterDevice
	return manager
}

// Run performs one exact-route capture and retains private evidence even when
// a post-reservation validation gate fails.
func (manager *Manager) Run(ctx context.Context, options Options) (Result, error) {
	if ctx == nil {
		return Result{}, fmt.Errorf("capture camera frames: context is nil")
	}
	if manager == nil || manager.Runner == nil || manager.mediaDevices == nil ||
		manager.runningRelease == nil || manager.modulePresent == nil ||
		manager.validateDevice == nil || manager.now == nil || manager.hostOS == "" {
		return Result{}, fmt.Errorf("camera capture manager is not initialised")
	}
	if manager.hostOS != "linux" {
		return Result{}, fmt.Errorf("native Surface camera capture requires Linux")
	}
	frames, err := normaliseFrames(options.Frames)
	if err != nil {
		return Result{}, err
	}
	runningRelease, err := manager.runningRelease(ctx)
	if err != nil {
		return Result{}, fmt.Errorf("read running kernel release: %w", err)
	}
	if err := validateRunningRelease(runningRelease, options.ExpectedRelease); err != nil {
		return Result{}, err
	}
	for _, module := range []string{"imx681", "qcom_camss", "phy_qcom_mipi_csi2"} {
		if !manager.modulePresent(module) {
			return Result{}, fmt.Errorf("required camera module %q is not loaded", module)
		}
	}
	pipeline, topologyBefore, err := manager.discover(ctx)
	if err != nil {
		return Result{}, err
	}
	for _, device := range []string{pipeline.MediaDevice, pipeline.VideoDevice} {
		inUse, err := manager.deviceInUse(ctx, device)
		if err != nil {
			return Result{}, err
		}
		if inUse {
			return Result{}, fmt.Errorf("camera device %s is already in use; close camera clients and retry", device)
		}
	}
	if options.DryRun {
		return Result{
			DryRun: true, RunningRelease: runningRelease, Frames: frames,
			Bytes: int64(frames) * int64(BytesPerFrame), Pipeline: pipeline,
			HardwareQualified: false,
		}, nil
	}
	prepared, err := prepareEvidence(options.OutputPath)
	if err != nil {
		return Result{}, err
	}
	if err := writeEvidence(prepared.paths.MediaBefore, topologyBefore); err != nil {
		return Result{}, err
	}
	if err := manager.configure(ctx, pipeline); err != nil {
		return Result{}, err
	}
	if err := manager.verifyVideoFormat(ctx, pipeline); err != nil {
		return Result{}, err
	}
	topologyAfter, err := manager.captureMetadata(ctx, Command{
		Name: "media-ctl", Args: []string{"-d", pipeline.MediaDevice, "--print-topology"},
	})
	if err != nil {
		return Result{}, fmt.Errorf("read configured camera topology: %w", err)
	}
	if err := writeEvidence(prepared.paths.MediaAfter, topologyAfter); err != nil {
		return Result{}, err
	}
	parsedAfter, err := parseTopology(string(topologyAfter))
	if err != nil {
		return Result{}, fmt.Errorf("parse configured camera topology: %w", err)
	}
	if err := validateConfiguredTopology(parsedAfter, pipeline); err != nil {
		return Result{}, err
	}
	logStart := manager.now()
	if err := manager.captureFrames(ctx, pipeline, prepared.paths, frames); err != nil {
		_ = manager.collectKernelLog(ctx, logStart, prepared.paths.KernelLog)
		return Result{}, err
	}
	if err := manager.collectKernelLog(ctx, logStart, prepared.paths.KernelLog); err != nil {
		return Result{}, err
	}
	if err := validateCaptureLog(prepared.paths.V4L2Log); err != nil {
		return Result{}, err
	}
	statistics, err := Analyse(ctx, prepared.paths.Raw, frames)
	if err != nil {
		return Result{}, err
	}
	if err := writeStatistics(prepared.paths.Statistics, statistics); err != nil {
		return Result{}, err
	}
	return Result{
		DryRun: false, RunningRelease: runningRelease, Frames: frames,
		Bytes: int64(frames) * int64(BytesPerFrame), Pipeline: pipeline,
		Evidence:              prepared.paths,
		SampleRange:           int(statistics.SampleMaximum) - int(statistics.SampleMinimum),
		DistinctCodes:         statistics.DistinctCodes,
		StandardDeviation:     statistics.StandardDeviation,
		EntropyBits:           statistics.EntropyBits,
		MinimumTemporalChange: statistics.MinimumTemporalChange,
		HardwareQualified:     false,
	}, nil
}

// normaliseFrames supplies the safe default and enforces the bounded range.
func normaliseFrames(value int) (int, error) {
	if value == 0 {
		return MinimumFrames, nil
	}
	if value < MinimumFrames || value > MaximumFrames {
		return 0, fmt.Errorf("camera frame count must be from %d through %d", MinimumFrames, MaximumFrames)
	}
	return value, nil
}

// validateRunningRelease accepts a current integrated Surface ABI and applies
// an optional exact caller-supplied release pin.
func validateRunningRelease(running, expected string) error {
	if strings.TrimSpace(running) == "" {
		return fmt.Errorf("running kernel release is empty")
	}
	if expected != "" && running != expected {
		return fmt.Errorf("running kernel is %q; expected %q", running, expected)
	}
	match := surfaceReleasePattern.FindStringSubmatch(running)
	if match == nil {
		return fmt.Errorf("running kernel %q is not a supported Surface qcom-x1e ABI", running)
	}
	generation, err := strconv.Atoi(match[1])
	if err != nil || generation < minimumCameraGeneration {
		return fmt.Errorf("running kernel %q predates the integrated IMX681 path", running)
	}
	return nil
}

// discover selects the sole matching controller graph and rejects missing,
// inaccessible, malformed, or ambiguous camera routes.
func (manager *Manager) discover(ctx context.Context) (Pipeline, []byte, error) {
	devices, err := manager.mediaDevices()
	if err != nil {
		return Pipeline{}, nil, fmt.Errorf("list media devices: %w", err)
	}
	if len(devices) == 0 || len(devices) > 64 {
		return Pipeline{}, nil, fmt.Errorf("expected from 1 through 64 media devices, found %d", len(devices))
	}
	type match struct {
		// pipeline is the exact route derived from one topology.
		pipeline Pipeline
		// content is the bounded original topology report.
		content []byte
	}
	var matches []match
	var failures []string
	for _, device := range devices {
		if !mediaDevicePattern.MatchString(device) {
			return Pipeline{}, nil, fmt.Errorf("refusing unexpected media-device path %q", device)
		}
		if err := manager.validateDevice(device); err != nil {
			failures = append(failures, fmt.Sprintf("%s is inaccessible", device))
			continue
		}
		content, captureErr := manager.captureMetadata(ctx, Command{
			Name: "media-ctl", Args: []string{"-d", device, "--print-topology"},
		})
		if captureErr != nil {
			failures = append(failures, fmt.Sprintf("%s could not be queried", device))
			continue
		}
		topology, parseErr := parseTopology(string(content))
		if parseErr != nil {
			failures = append(failures, fmt.Sprintf("%s returned malformed topology", device))
			continue
		}
		pipeline, discoverErr := discoverPipeline(device, topology)
		if discoverErr != nil {
			continue
		}
		if err := validatePipelineNames(pipeline); err != nil {
			return Pipeline{}, nil, err
		}
		matches = append(matches, match{pipeline: pipeline, content: content})
	}
	if len(matches) == 0 {
		detail := "no media device contains the exact IMX681 to CSIPHY2 to CSID0 to VFE0-RDI0 route"
		if len(failures) != 0 {
			detail += "; " + strings.Join(failures, "; ")
		}
		return Pipeline{}, nil, fmt.Errorf("%s", detail)
	}
	if len(matches) != 1 {
		return Pipeline{}, nil, fmt.Errorf("found %d matching IMX681 camera graphs; refusing ambiguous capture", len(matches))
	}
	if err := manager.validateDevice(matches[0].pipeline.VideoDevice); err != nil {
		return Pipeline{}, nil, fmt.Errorf("validate discovered video device: %w", err)
	}
	return matches[0].pipeline, matches[0].content, nil
}

// validatePipelineNames prevents untrusted topology text from becoming
// media-ctl mini-language syntax or an arbitrary device path.
func validatePipelineNames(pipeline Pipeline) error {
	for _, name := range []string{pipeline.SensorEntity, pipeline.VideoEntity} {
		if !entityNamePattern.MatchString(name) || strings.ContainsAny(name, `"[]\\`) {
			return fmt.Errorf("camera topology contains an unsafe entity name")
		}
	}
	if !videoDevicePattern.MatchString(pipeline.VideoDevice) {
		return fmt.Errorf("camera topology contains an unsafe video-device path")
	}
	if pipeline.SensorControlDevice != "" && !subdevicePattern.MatchString(pipeline.SensorControlDevice) {
		return fmt.Errorf("camera topology contains an unsafe sensor-control path")
	}
	return nil
}

// configure enables only the two mutable links and writes the exact validated
// media and packed-video formats without resetting unrelated graph state.
func (manager *Manager) configure(ctx context.Context, pipeline Pipeline) error {
	commands := []Command{
		mediaLinkCommand(pipeline.MediaDevice, phyEntity, 1, csidEntity, 0),
		mediaLinkCommand(pipeline.MediaDevice, csidEntity, 1, vfeEntity, 0),
		mediaFormatCommand(pipeline.MediaDevice, pipeline.SensorEntity, pipeline.SensorSourcePad, pipeline.MediaBusFormat, sensorWidth),
		mediaFormatCommand(pipeline.MediaDevice, phyEntity, 0, pipeline.MediaBusFormat, sensorWidth),
		mediaFormatCommand(pipeline.MediaDevice, phyEntity, 1, pipeline.MediaBusFormat, sensorWidth),
		mediaFormatCommand(pipeline.MediaDevice, csidEntity, 0, pipeline.MediaBusFormat, sensorWidth),
		mediaFormatCommand(pipeline.MediaDevice, csidEntity, 1, pipeline.MediaBusFormat, Width),
		mediaFormatCommand(pipeline.MediaDevice, vfeEntity, 0, pipeline.MediaBusFormat, Width),
		mediaFormatCommand(pipeline.MediaDevice, vfeEntity, 1, pipeline.MediaBusFormat, Width),
		{Name: "v4l2-ctl", Args: []string{"-d", pipeline.VideoDevice,
			fmt.Sprintf("--set-fmt-video=width=%d,height=%d,pixelformat=%s", Width, Height, pipeline.PixelFormat)}},
	}
	for _, command := range commands {
		commandContext, cancel := context.WithTimeout(ctx, metadataTimeout)
		err := manager.Runner.Run(commandContext, command, io.Discard, io.Discard)
		cancel()
		if err != nil {
			return fmt.Errorf("configure camera route: %w", err)
		}
	}
	return nil
}

// mediaLinkCommand constructs one exact enabled-link media-ctl request.
func mediaLinkCommand(device, source string, sourcePad int, target string, targetPad int) Command {
	link := fmt.Sprintf("\"%s\":%d -> \"%s\":%d [1]", source, sourcePad, target, targetPad)
	return Command{Name: "media-ctl", Args: []string{"-d", device, "--links", link}}
}

// mediaFormatCommand constructs one exact pad-format media-ctl request.
func mediaFormatCommand(device, entity string, pad int, format string, width int) Command {
	value := fmt.Sprintf("\"%s\":%d [fmt:%s/%dx%d]", entity, pad, format, width, Height)
	return Command{Name: "media-ctl", Args: []string{"-d", device, "--set-v4l2", value}}
}

// verifyVideoFormat proves resolution, fourcc, stride, and image size after
// the device has negotiated the requested packed format.
func (manager *Manager) verifyVideoFormat(ctx context.Context, pipeline Pipeline) error {
	content, err := manager.captureMetadata(ctx, Command{
		Name: "v4l2-ctl", Args: []string{"-d", pipeline.VideoDevice, "--get-fmt-video"},
	})
	if err != nil {
		return fmt.Errorf("read configured video format: %w", err)
	}
	text := string(content)
	if match := widthHeightPattern.FindStringSubmatch(text); match == nil || match[1] != strconv.Itoa(Width) || match[2] != strconv.Itoa(Height) {
		return fmt.Errorf("video node did not negotiate %dx%d", Width, Height)
	}
	if match := pixelFormatPattern.FindStringSubmatch(text); match == nil || match[1] != pipeline.PixelFormat {
		return fmt.Errorf("video node did not negotiate packed RAW10 fourcc %s", pipeline.PixelFormat)
	}
	if err := validateOptionalNumericField(text, bytesPerLinePattern, BytesPerLine, "bytes per line"); err != nil {
		return err
	}
	return validateOptionalNumericField(text, sizeImagePattern, BytesPerFrame, "image size")
}

// validateOptionalNumericField checks an optional v4l2-ctl numeric report.
func validateOptionalNumericField(text string, pattern *regexp.Regexp, expected int, label string) error {
	match := pattern.FindStringSubmatch(text)
	if match == nil {
		return nil
	}
	value, err := strconv.Atoi(match[1])
	if err != nil || value != expected {
		return fmt.Errorf("negotiated camera %s is %s; expected %d", label, match[1], expected)
	}
	return nil
}

// captureFrames streams an exact bounded frame count into the reserved raw
// file and caps all retained diagnostic output.
func (manager *Manager) captureFrames(ctx context.Context, pipeline Pipeline, evidence Evidence, frames int) error {
	logFile, logWriter, err := openEvidenceLog(evidence.V4L2Log)
	if err != nil {
		return err
	}
	captureTimeout := time.Duration(20+frames*2) * time.Second
	captureContext, cancel := context.WithTimeout(ctx, captureTimeout)
	command := Command{Name: "v4l2-ctl", Args: []string{
		"--verbose", "-d", pipeline.VideoDevice, "--stream-mmap=4",
		fmt.Sprintf("--stream-count=%d", frames), "--stream-to=" + evidence.Raw,
	}}
	runErr := manager.Runner.Run(captureContext, command, logWriter, logWriter)
	cancel()
	syncErr := logFile.Sync()
	closeErr := logFile.Close()
	if logWriter.exceeded {
		return fmt.Errorf("camera streaming log exceeded the compiled limit")
	}
	if err := errors.Join(runErr, syncErr, closeErr); err != nil {
		return fmt.Errorf("capture camera frames: %w", err)
	}
	info, err := os.Lstat(evidence.Raw)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("camera capture output is no longer a regular file")
	}
	expected := int64(frames) * int64(BytesPerFrame)
	if info.Size() != expected {
		return fmt.Errorf("camera capture is %d bytes; expected exactly %d", info.Size(), expected)
	}
	return nil
}

// collectKernelLog retains only bounded camera-related post-capture lines and
// rejects emitted FIFO, image, truncation, stop, or halt failures.
func (manager *Manager) collectKernelLog(ctx context.Context, since time.Time, path string) error {
	timestamp := since.UTC().Format("2006-01-02 15:04:05")
	commands := []Command{
		{Name: "journalctl", Args: []string{"-k", "-b", "--since", timestamp, "--no-pager", "-o", "short-monotonic"}},
		{Name: "dmesg", Args: []string{"--color=never", "--since", timestamp}},
	}
	var content []byte
	var lastErr error
	for _, command := range commands {
		content, lastErr = manager.captureMetadata(ctx, command)
		if lastErr == nil && len(bytes.TrimSpace(content)) != 0 {
			break
		}
	}
	if lastErr != nil || len(bytes.TrimSpace(content)) == 0 {
		return fmt.Errorf("collect post-capture kernel log: no readable journal or dmesg source")
	}
	var selected []string
	for _, line := range strings.Split(strings.ReplaceAll(string(content), "\r\n", "\n"), "\n") {
		if cameraLinePattern.MatchString(line) {
			selected = append(selected, line)
			if cameraViolationPattern.MatchString(line) {
				_ = writeEvidence(path, []byte(strings.Join(selected, "\n")+"\n"))
				return fmt.Errorf("camera capture failed the emitted-error kernel-log gate")
			}
		}
	}
	return writeEvidence(path, []byte(strings.Join(selected, "\n")+"\n"))
}

// validateCaptureLog verifies every non-zero bytes-used report when the host
// v4l2-ctl version emits per-buffer sizes.
func validateCaptureLog(path string) error {
	content, err := readRegularNoFollow(path, maximumEvidenceLogBytes)
	if err != nil {
		return fmt.Errorf("read camera streaming log: %w", err)
	}
	for _, match := range bytesUsedPattern.FindAllSubmatch(content, -1) {
		value, parseErr := strconv.Atoi(string(match[1]))
		if parseErr != nil {
			return fmt.Errorf("parse camera bytes-used report: %w", parseErr)
		}
		if value != 0 && value != BytesPerFrame {
			return fmt.Errorf("camera buffer reports bytes-used %d; expected %d", value, BytesPerFrame)
		}
	}
	return nil
}

// captureMetadata runs one bounded short-lived camera command.
func (manager *Manager) captureMetadata(ctx context.Context, command Command) ([]byte, error) {
	commandContext, cancel := context.WithTimeout(ctx, metadataTimeout)
	defer cancel()
	return manager.Runner.Capture(commandContext, command, maximumMetadataBytes)
}

// deviceInUse runs the compiled fuser probe and retains neither process IDs nor
// command output; exit status one means the device has no current users.
func (manager *Manager) deviceInUse(ctx context.Context, path string) (bool, error) {
	commandContext, cancel := context.WithTimeout(ctx, metadataTimeout)
	defer cancel()
	output := &boundedBuffer{limit: 4096}
	err := manager.Runner.Run(commandContext, Command{Name: "fuser", Args: []string{path}}, output, output)
	if output.seen > output.limit {
		return false, fmt.Errorf("camera device-use probe exceeded the compiled limit")
	}
	if err == nil {
		return true, nil
	}
	type exitCoder interface {
		// ExitCode returns the child process status.
		ExitCode() int
	}
	var status exitCoder
	if errors.As(err, &status) && status.ExitCode() == 1 {
		return false, nil
	}
	return false, fmt.Errorf("check whether camera device is in use: fuser is unavailable or failed")
}

// validateCharacterDevice proves a selected camera path is a non-symbolic
// character device that the current process can open read-write.
func validateCharacterDevice(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || info.Mode()&os.ModeCharDevice == 0 {
		return fmt.Errorf("camera node is not a direct character device")
	}
	file, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	return file.Close()
}
