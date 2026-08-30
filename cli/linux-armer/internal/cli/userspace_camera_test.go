package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/rawpreview"
)

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
