package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	cameracapture "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/capture"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/rawpreview"
)

// cameraCaptureStub records delivery options and returns one injected result.
type cameraCaptureStub struct {
	// options records the latest command request.
	options cameracapture.Options
	// result is returned after recording the request.
	result cameracapture.Result
	// err is the optional domain failure returned after recording the request.
	err error
}

// Run records one capture request and returns the configured result or error.
func (stub *cameraCaptureStub) Run(_ context.Context, options cameracapture.Options) (cameracapture.Result, error) {
	stub.options = options
	return stub.result, stub.err
}

// TestUserspaceCameraCaptureDeliversNativeOptionsAsJSON verifies every public
// capture flag reaches the native workflow without shell interpretation.
func TestUserspaceCameraCaptureDeliversNativeOptionsAsJSON(t *testing.T) {
	t.Parallel()
	stub := &cameraCaptureStub{result: cameracapture.Result{
		DryRun: true, RunningRelease: "7.2.0-jg-0sp11v19-qcom-x1e",
		Frames: 12, Bytes: 12 * cameracapture.BytesPerFrame,
		Pipeline: cameracapture.Pipeline{VideoDevice: "/dev/video12", BayerOrder: cameracapture.BayerRGGB},
	}}
	var output bytes.Buffer
	app := &application{out: &output}
	command := app.newUserspaceCameraCaptureCommand(stub)
	command.SetArgs([]string{"--frames", "12", "--output", "private.raw", "--expected-release", "abi", "--dry-run", "--json"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if stub.options.Frames != 12 || stub.options.OutputPath != "private.raw" || stub.options.ExpectedRelease != "abi" || !stub.options.DryRun {
		t.Fatalf("capture options = %#v", stub.options)
	}
	var result cameracapture.Result
	if err := json.Unmarshal(output.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if !result.DryRun || result.Pipeline.VideoDevice != "/dev/video12" {
		t.Fatalf("JSON result = %#v", result)
	}
}

// TestUserspaceCameraCaptureHumanOutputKeepsManualGatesExplicit verifies a
// passed byte/content result never becomes an unsupported hardware claim.
func TestUserspaceCameraCaptureHumanOutputKeepsManualGatesExplicit(t *testing.T) {
	t.Parallel()
	stub := &cameraCaptureStub{result: cameracapture.Result{
		RunningRelease: "7.2.0-jg-0sp11v19-qcom-x1e", Frames: 10,
		Bytes:       10 * cameracapture.BytesPerFrame,
		Pipeline:    cameracapture.Pipeline{BayerOrder: cameracapture.BayerBGGR, PixelFormat: "pBAA"},
		Evidence:    cameracapture.Evidence{Raw: "capture.raw", Statistics: "capture.raw.stats.json"},
		SampleRange: 32, DistinctCodes: 16, StandardDeviation: 3, EntropyBits: 2,
		MinimumTemporalChange: 0.5,
	}}
	var output bytes.Buffer
	app := &application{out: &output}
	command := app.newUserspaceCameraCaptureCommand(stub)
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{"sampled-content gates passed", "Hardware qualification is still not proven", "privacy LED", "suspend/resume"} {
		if !strings.Contains(output.String(), expected) {
			t.Fatalf("capture output omitted %q:\n%s", expected, output.String())
		}
	}
}

// TestUserspaceCameraCaptureWrapsDomainErrors verifies unsafe or unavailable
// hardware failures remain clearly attributed to the native validator.
func TestUserspaceCameraCaptureWrapsDomainErrors(t *testing.T) {
	t.Parallel()
	stub := &cameraCaptureStub{err: errors.New("fixture route unavailable")}
	command := (&application{out: &bytes.Buffer{}}).newUserspaceCameraCaptureCommand(stub)
	if err := command.Execute(); err == nil || !strings.Contains(err.Error(), "validate live IMX681 capture: fixture route unavailable") {
		t.Fatalf("capture error = %v", err)
	}
}

// TestUserspaceCameraRenderDeliversTheNativePlan verifies flag parsing and JSON delivery.
func TestUserspaceCameraRenderDeliversTheNativePlan(t *testing.T) {
	var captured rawpreview.Options
	renderer := func(options rawpreview.Options) (rawpreview.Result, error) {
		captured = options
		return rawpreview.Result{
			InputPath: options.InputPath, OutputPath: options.OutputPath,
			FrameIndex: options.FrameIndex, BayerOrder: options.BayerOrder,
			Mapping: "linear 0..1023", LowerCode: 0, UpperCode: 1023,
			Width: 1920, Height: 1320, Bytes: 128,
		}, nil
	}
	var output bytes.Buffer
	app := &application{out: &output}
	command := app.newUserspaceCameraRenderCommand(renderer)
	command.SetArgs([]string{"capture.raw", "preview.png", "--frame", "3", "--bayer-order", "GBRG", "--linear", "--json"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if captured.FrameIndex != 3 || captured.BayerOrder != rawpreview.BayerGBRG || !captured.Linear {
		t.Fatalf("unexpected options: %+v", captured)
	}
	var report rawpreview.Result
	if err := json.Unmarshal(output.Bytes(), &report); err != nil {
		t.Fatal(err)
	}
	if report.OutputPath != "preview.png" || report.Bytes != 128 {
		t.Fatalf("unexpected report: %+v", report)
	}
}

// TestUserspaceCameraRenderWritesHumanGuidanceAndWrapsDomainErrors checks both delivery paths.
func TestUserspaceCameraRenderWritesHumanGuidanceAndWrapsDomainErrors(t *testing.T) {
	renderer := func(options rawpreview.Options) (rawpreview.Result, error) {
		return rawpreview.Result{
			OutputPath: options.OutputPath, FrameIndex: options.FrameIndex,
			BayerOrder: rawpreview.BayerRGGB, Mapping: "preview stretch 10..900",
			Width: 1920, Height: 1320,
		}, nil
	}
	var output bytes.Buffer
	app := &application{out: &output}
	command := app.newUserspaceCameraRenderCommand(renderer)
	command.SetArgs([]string{"capture.raw", "preview.png", "--bayer-order", "RGGB"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if rendered := output.String(); !strings.Contains(rendered, "auto-stretched") || !strings.Contains(rendered, "preview.png") {
		t.Fatalf("human output omitted guidance: %s", rendered)
	}

	failing := app.newUserspaceCameraRenderCommand(func(rawpreview.Options) (rawpreview.Result, error) {
		return rawpreview.Result{}, errors.New("fixture failure")
	})
	failing.SetArgs([]string{"capture.raw", "preview.png"})
	if err := failing.Execute(); err == nil || !strings.Contains(err.Error(), "render private camera preview: fixture failure") {
		t.Fatalf("expected wrapped renderer error, got %v", err)
	}
}

// TestUserspaceCameraRenderRejectsNegativeFramesAndWrongArity validates its CLI boundary.
func TestUserspaceCameraRenderRejectsNegativeFramesAndWrongArity(t *testing.T) {
	called := false
	renderer := func(rawpreview.Options) (rawpreview.Result, error) {
		called = true
		return rawpreview.Result{}, nil
	}
	app := &application{out: &bytes.Buffer{}}
	negative := app.newUserspaceCameraRenderCommand(renderer)
	negative.SetArgs([]string{"capture.raw", "preview.png", "--frame", "-1"})
	if err := negative.Execute(); err == nil || !strings.Contains(err.Error(), "must not be negative") {
		t.Fatalf("expected negative-frame rejection, got %v", err)
	}
	wrongArity := app.newUserspaceCameraRenderCommand(renderer)
	wrongArity.SetArgs([]string{"capture.raw"})
	if err := wrongArity.Execute(); err == nil {
		t.Fatal("expected wrong arity to be rejected")
	}
	if called {
		t.Fatal("renderer ran after invalid CLI input")
	}
}

// TestRootRegistersTheUserspaceCameraRenderer protects command-tree discoverability.
func TestRootRegistersTheUserspaceCameraRenderer(t *testing.T) {
	root := NewRootCommand(strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
	command, remaining, err := root.Find([]string{"userspace", "camera", "render"})
	if err != nil {
		t.Fatal(err)
	}
	if command.CommandPath() != "linux-armer userspace camera render" || len(remaining) != 0 {
		t.Fatalf("unexpected command resolution: %s %#v", command.CommandPath(), remaining)
	}
}

// TestRootRegistersTheUserspaceCameraCapture protects native camera-validator
// discoverability in both packaged and companion CLI builds.
func TestRootRegistersTheUserspaceCameraCapture(t *testing.T) {
	t.Parallel()
	root := NewRootCommand(strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
	command, remaining, err := root.Find([]string{"userspace", "camera", "capture"})
	if err != nil {
		t.Fatal(err)
	}
	if command.CommandPath() != "linux-armer userspace camera capture" || len(remaining) != 0 {
		t.Fatalf("unexpected command resolution: %s %#v", command.CommandPath(), remaining)
	}
}

// TestUserspaceCameraRenderRejectsAnUnknownBayerOrderBeforeRendering protects strict dispatch.
func TestUserspaceCameraRenderRejectsAnUnknownBayerOrderBeforeRendering(t *testing.T) {
	called := false
	renderer := func(rawpreview.Options) (rawpreview.Result, error) {
		called = true
		return rawpreview.Result{}, nil
	}
	app := &application{out: &bytes.Buffer{}}
	command := app.newUserspaceCameraRenderCommand(renderer)
	command.SetArgs([]string{"capture.raw", "preview.png", "--bayer-order", "rggb"})
	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "unsupported Bayer order") {
		t.Fatalf("expected strict Bayer error, got %v", err)
	}
	if called {
		t.Fatal("renderer ran after invalid delivery input")
	}
}
