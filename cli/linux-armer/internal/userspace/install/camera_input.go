package install

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	camerabuild "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/build"
	camerarelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/release"
)

const (
	// sha256HexLength is the canonical lowercase text length of a SHA-256 digest.
	sha256HexLength = 64
	// maximumNativeCameraBuildAuthorityBytes mirrors the native build receipt limit.
	maximumNativeCameraBuildAuthorityBytes int64 = 4 << 20
	// maximumNativeCameraReleaseAuthorityBytes mirrors the release manifest limit.
	maximumNativeCameraReleaseAuthorityBytes int64 = 8 << 20
)

// cameraInput identifies the five runtime packages selected by one completely
// validated camera authority.
type cameraInput struct {
	// paths maps each verified runtime package basename to its canonical source.
	paths map[string]string
	// runtimeFiles preserves the compiled package installation order.
	runtimeFiles []immutableFile
}

// cameraAuthorityPresence reports whether one authority is a regular direct
// child of the selected directory, rejecting links and unreadable metadata.
func cameraAuthorityPresence(directory, name string) (bool, error) {
	path := filepath.Join(directory, name)
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("inspect camera authority %s: %w", name, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return false, fmt.Errorf("camera authority must be a regular, non-symlink file: %s", path)
	}
	return true, nil
}

// verifyCameraInput selects exactly one supported authority family and returns
// only package paths which survived its complete validation contract.
func (installer *Installer) verifyCameraInput(ctx context.Context, options Options) (cameraInput, error) {
	downloaded, err := cameraAuthorityPresence(options.BundleDir, bundleManifestName)
	if err != nil {
		return cameraInput{}, err
	}
	nativeBuild, err := cameraAuthorityPresence(options.BundleDir, camerabuild.ReceiptName)
	if err != nil {
		return cameraInput{}, err
	}
	nativeRelease, err := cameraAuthorityPresence(options.BundleDir, camerarelease.ManifestName)
	if err != nil {
		return cameraInput{}, err
	}

	if downloaded && (nativeBuild || nativeRelease) {
		return cameraInput{}, errors.New("camera directory mixes downloaded and native authority files")
	}
	if nativeRelease && !nativeBuild {
		return cameraInput{}, fmt.Errorf("native camera release is missing %s", camerabuild.ReceiptName)
	}

	switch {
	case downloaded:
		if options.RepositoryRoot != "" || options.CameraAuthoritySHA256 != "" {
			return cameraInput{}, errors.New("repository root and camera authority SHA-256 apply only to native camera input")
		}
		bundle, err := verifyBundle(options.BundleDir, cameraSpec)
		if err != nil {
			return cameraInput{}, err
		}
		return cameraInput{
			paths:        bundle.paths,
			runtimeFiles: append([]immutableFile(nil), cameraRuntimeFiles...),
		}, nil
	case nativeRelease:
		if options.RepositoryRoot == "" {
			return cameraInput{}, errors.New("repository root is required to authenticate a native camera release")
		}
		if err := verifyExpectedCameraAuthority(options.BundleDir, camerarelease.ManifestName, options.CameraAuthoritySHA256); err != nil {
			return cameraInput{}, err
		}
		if installer == nil || installer.validateCameraRelease == nil {
			return cameraInput{}, errors.New("native camera release validator is unavailable")
		}
		receipt, err := installer.validateCameraRelease(ctx, installer.runner, camerarelease.ValidationRequest{
			RepositoryRoot:          options.RepositoryRoot,
			Directory:               options.BundleDir,
			ExpectedAuthoritySHA256: options.CameraAuthoritySHA256,
		})
		if err != nil {
			return cameraInput{}, fmt.Errorf("validate native camera release: %w", err)
		}
		return nativeCameraInput(options.BundleDir, receipt.Manifest.Build)
	case nativeBuild:
		if options.RepositoryRoot == "" {
			return cameraInput{}, errors.New("repository root is required to authenticate a native camera build")
		}
		if err := verifyExpectedCameraAuthority(options.BundleDir, camerabuild.ReceiptName, options.CameraAuthoritySHA256); err != nil {
			return cameraInput{}, err
		}
		if installer == nil || installer.validateCameraBuild == nil {
			return cameraInput{}, errors.New("native camera build validator is unavailable")
		}
		receipt, err := installer.validateCameraBuild(ctx, installer.runner, camerabuild.ValidationRequest{
			RepositoryRoot:          options.RepositoryRoot,
			Directory:               options.BundleDir,
			ExpectedAuthoritySHA256: options.CameraAuthoritySHA256,
		})
		if err != nil {
			return cameraInput{}, fmt.Errorf("validate native camera build: %w", err)
		}
		return nativeCameraInput(options.BundleDir, receipt)
	default:
		return cameraInput{}, fmt.Errorf(
			"camera directory contains no supported authority; expected %s, %s, or %s",
			bundleManifestName,
			camerabuild.ReceiptName,
			camerarelease.ManifestName,
		)
	}
}

// verifyExpectedCameraAuthority binds a native directory to the digest retained
// independently from the trusted build or release-preparation invocation.
func verifyExpectedCameraAuthority(directory, name, expected string) error {
	if len(expected) != sha256HexLength || strings.ToLower(expected) != expected {
		return errors.New("native camera authority SHA-256 must be exactly 64 lowercase hexadecimal characters")
	}
	if _, err := hex.DecodeString(expected); err != nil {
		return errors.New("native camera authority SHA-256 must be exactly 64 lowercase hexadecimal characters")
	}
	maximum := maximumNativeCameraBuildAuthorityBytes
	if name == camerarelease.ManifestName {
		maximum = maximumNativeCameraReleaseAuthorityBytes
	}
	digest, _, err := hashRegularNoFollowBounded(filepath.Join(directory, name), maximum)
	if err != nil {
		return fmt.Errorf("hash native camera authority %s: %w", name, err)
	}
	if digest != expected {
		return fmt.Errorf("native camera authority SHA-256 mismatch for %s", name)
	}
	return nil
}

// nativeCameraInput derives the exact runtime paths, lengths, and digests from
// a receipt already authenticated by the native camera build domain.
func nativeCameraInput(directory string, receipt camerabuild.BundleReceipt) (cameraInput, error) {
	artifacts := make(map[string]camerabuild.Artifact, len(receipt.Artifacts))
	for _, artifact := range receipt.Artifacts {
		if _, duplicate := artifacts[artifact.Name]; duplicate {
			return cameraInput{}, fmt.Errorf("native camera receipt repeats artefact %q", artifact.Name)
		}
		artifacts[artifact.Name] = artifact
	}

	packageNames := camerabuild.RuntimePackageNames()
	runtimeFiles := make([]immutableFile, 0, len(packageNames))
	paths := make(map[string]string, len(packageNames))
	for _, packageName := range packageNames {
		name := packageName + "_" + receipt.PackageVersion + "_arm64.deb"
		artifact, ok := artifacts[name]
		if !ok {
			return cameraInput{}, fmt.Errorf("native camera receipt is missing runtime package %s", name)
		}
		path, err := requireRegularBundleFile(directory, name)
		if err != nil {
			return cameraInput{}, err
		}
		runtimeFiles = append(runtimeFiles, immutableFile{name: name, sha256: artifact.SHA256, size: artifact.Size})
		paths[name] = path
	}
	return cameraInput{paths: paths, runtimeFiles: runtimeFiles}, nil
}
