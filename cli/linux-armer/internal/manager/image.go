// Package manager orchestrates feature packages into complete user workflows.
package manager

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/artifact"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/catalog"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image/ubuntu"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/release"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/plan"
)

// DefaultCatalogID selects the first source image whose adapter is implemented
// when a caller does not explicitly choose a catalogue entry.
const DefaultCatalogID = "ubuntu-concept-resolute-x1e"

// CreateImageRequest describes source, kernel, cache, workspace, and publication
// choices for the complete image-creation workflow.
type CreateImageRequest struct {
	// CatalogPath optionally overrides the embedded supported-image catalogue.
	CatalogPath string
	// CatalogID selects the source image metadata and distribution adapter.
	CatalogID string
	// Source optionally overrides the catalogue download URL with a URL or local file.
	Source string
	// SourceSHA256 pins the selected source bytes when supplied.
	SourceSHA256 string
	// RefreshSource discards a cached download before resolving the source again.
	RefreshSource bool
	// KernelDirectory selects an already downloaded, locally verifiable bundle.
	KernelDirectory string
	// KernelRepository identifies the GitHub repository used for release bundles.
	KernelRepository string
	// KernelRelease selects an exact tag or the repository's latest release.
	KernelRelease string
	// CacheDirectory optionally overrides the per-user artefact cache.
	CacheDirectory string
	// WorkspaceRoot optionally controls where temporary host workspaces are created.
	WorkspaceRoot string
	// Output is the destination ISO path published after validation.
	Output string
	// KeepWorkspace retains diagnostic build state instead of cleaning it.
	KeepWorkspace bool
	// ToolVersion is embedded in image provenance.
	ToolVersion string
}

// CreateImageResult returns the resolved catalogue and kernel inputs together with
// the remaster adapter's published artefacts.
type CreateImageResult struct {
	// CatalogEntry is the validated distribution source metadata used by the build.
	CatalogEntry catalog.Entry
	// KernelBundle is the exact digest-verified bundle installed into the image.
	KernelBundle kernel.Bundle
	// Image contains the ISO, manifest, journal, digest, and optional diagnostics.
	Image ubuntu.Result
}

// ImageManager orchestrates otherwise independent catalogue, download, release,
// and remaster packages into one end-to-end image workflow.
type ImageManager struct {
	// Catalogs loads either the embedded or explicitly supplied source catalogue.
	Catalogs catalog.Loader
	// Artifacts downloads and verifies source media.
	Artifacts *artifact.Resolver
	// Releases resolves candidate release assets and verifies them before use.
	Releases *release.Client
	// Remaster performs the distribution-specific image transformation.
	Remaster *ubuntu.Remasterer
}

// NewImageManager constructs an image workflow with production resolvers and a
// caller-provided catalogue loader and progress writer.
func NewImageManager(loader catalog.Loader, out io.Writer) *ImageManager {
	return &ImageManager{
		Catalogs:  loader,
		Artifacts: artifact.NewResolver(nil),
		Releases:  release.NewClient(nil),
		Remaster:  ubuntu.NewRemasterer(nil, out),
	}
}

// Plan describes the externally visible workflow without downloading or
// mutating anything. The adapter later produces a more detailed execution
// plan after the exact kernel ABI is known.
func (m *ImageManager) Plan(request CreateImageRequest) (plan.Plan, error) {
	request = imageDefaults(request)
	if strings.TrimSpace(request.Output) == "" {
		return plan.Plan{}, errors.New("output ISO path is required")
	}
	kernelInput := request.KernelDirectory
	if kernelInput == "" {
		kernelInput = request.KernelRepository + "@" + request.KernelRelease
	}
	sourceInput := request.Source
	if sourceInput == "" {
		sourceInput = "catalog:" + request.CatalogID
	}
	return ubuntu.BuildPlan(ubuntu.Request{
		SourceISO:    sourceInput,
		SourceSHA256: request.SourceSHA256,
		OutputISO:    request.Output,
		Bundle: kernel.Bundle{
			Release: kernelInput,
			ABI:     "resolved-at-execution",
		},
	})
}

// Create resolves and verifies every external input, invokes the supported
// distribution adapter, and returns only after the image is validated and published.
func (m *ImageManager) Create(ctx context.Context, request CreateImageRequest) (CreateImageResult, error) {
	request = imageDefaults(request)
	if _, err := m.Plan(request); err != nil {
		return CreateImageResult{}, err
	}
	if m.Artifacts == nil || m.Releases == nil || m.Remaster == nil {
		return CreateImageResult{}, errors.New("image manager dependencies are incomplete")
	}
	mediaCatalog, err := m.Catalogs.Load(request.CatalogPath)
	if err != nil {
		return CreateImageResult{}, err
	}
	entry, ok := mediaCatalog.Get(request.CatalogID)
	if !ok {
		return CreateImageResult{}, fmt.Errorf("catalog entry %q was not found", request.CatalogID)
	}
	if entry.SupportLevel != catalog.SupportLevelImplemented || entry.Adapter != catalog.AdapterUbuntuCasper {
		return CreateImageResult{}, fmt.Errorf("catalog entry %q is %s and cannot yet be created", entry.ID, entry.SupportLevel)
	}

	cacheDirectory, err := resolveCacheDirectory(request.CacheDirectory)
	if err != nil {
		return CreateImageResult{}, err
	}
	if err := os.MkdirAll(cacheDirectory, 0o755); err != nil {
		return CreateImageResult{}, fmt.Errorf("create cache directory: %w", err)
	}

	bundle, err := m.resolveBundle(ctx, request, cacheDirectory)
	if err != nil {
		return CreateImageResult{}, err
	}
	sourcePath, sourceDigest, err := m.resolveSource(ctx, request, entry, cacheDirectory)
	if err != nil {
		return CreateImageResult{}, err
	}
	result, err := m.Remaster.Create(ctx, ubuntu.Request{
		SourceISO:     sourcePath,
		SourceSHA256:  sourceDigest,
		OutputISO:     request.Output,
		Bundle:        bundle,
		ToolVersion:   request.ToolVersion,
		WorkspaceRoot: request.WorkspaceRoot,
		KeepWorkspace: request.KeepWorkspace,
	})
	if err != nil {
		return CreateImageResult{}, err
	}
	return CreateImageResult{CatalogEntry: entry, KernelBundle: bundle, Image: result}, nil
}

// resolveBundle chooses a caller-supplied local bundle or downloads an exact
// release into the cache, applying the kernel package's integrity contract either way.
func (m *ImageManager) resolveBundle(ctx context.Context, request CreateImageRequest, cacheDirectory string) (kernel.Bundle, error) {
	if request.KernelDirectory != "" {
		return kernel.DiscoverLocalBundle(request.KernelDirectory)
	}
	destination := filepath.Join(cacheDirectory, "kernels", safePathComponent(request.KernelRelease))
	bundle, err := m.Releases.DownloadBundle(ctx, request.KernelRepository, request.KernelRelease, destination, false)
	if err != nil {
		return kernel.Bundle{}, fmt.Errorf("resolve kernel release: %w", err)
	}
	return bundle, nil
}

// resolveSource obtains the catalogue or override image, verifies any available
// SHA-256 pin, and returns an absolute local path plus its measured digest.
func (m *ImageManager) resolveSource(ctx context.Context, request CreateImageRequest, entry catalog.Entry, cacheDirectory string) (string, string, error) {
	location := request.Source
	if location == "" {
		location = entry.URL
	}
	expected := strings.ToLower(strings.TrimSpace(request.SourceSHA256))
	if expected == "" && entry.Checksum != nil && strings.EqualFold(entry.Checksum.Algorithm, "sha256") {
		expected = strings.ToLower(entry.Checksum.Value)
	}
	parsed, err := url.Parse(location)
	if err != nil {
		return "", "", fmt.Errorf("parse source image location: %w", err)
	}
	if parsed.Scheme == "https" || parsed.Scheme == "http" {
		destination := filepath.Join(cacheDirectory, "images", entry.ID+".iso")
		if request.RefreshSource {
			if err := os.Remove(destination); err != nil && !errors.Is(err, os.ErrNotExist) {
				return "", "", fmt.Errorf("refresh cached source image: %w", err)
			}
		}
		result, err := m.Artifacts.Acquire(ctx, artifact.Source{Location: location, ExpectedSHA256: expected}, destination)
		if err != nil {
			return "", "", err
		}
		return result.Path, result.SHA256, nil
	}
	path := location
	if parsed.Scheme == "file" {
		path = parsed.Path
	} else if parsed.Scheme != "" {
		return "", "", fmt.Errorf("unsupported source image scheme %q", parsed.Scheme)
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", "", err
	}
	info, err := os.Stat(absolute)
	if err != nil {
		return "", "", fmt.Errorf("stat source image: %w", err)
	}
	if !info.Mode().IsRegular() {
		return "", "", fmt.Errorf("source image is not a regular file: %s", absolute)
	}
	digest, err := artifact.HashFile(absolute)
	if err != nil {
		return "", "", err
	}
	if expected != "" && !strings.EqualFold(expected, digest) {
		return "", "", fmt.Errorf("source ISO SHA-256 mismatch: expected %s, got %s", expected, digest)
	}
	return absolute, digest, nil
}

// imageDefaults fills only optional catalogue and release selectors, leaving all
// caller paths and integrity pins unchanged.
func imageDefaults(request CreateImageRequest) CreateImageRequest {
	if request.CatalogID == "" {
		request.CatalogID = DefaultCatalogID
	}
	if request.KernelRepository == "" {
		request.KernelRepository = release.DefaultRepository
	}
	if request.KernelRelease == "" {
		request.KernelRelease = "latest"
	}
	return request
}

// resolveCacheDirectory returns an absolute caller override or the standard
// per-user linux-armer cache without creating it.
func resolveCacheDirectory(configured string) (string, error) {
	if configured != "" {
		return filepath.Abs(configured)
	}
	base, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("resolve user cache directory: %w", err)
	}
	return filepath.Join(base, "linux-armer"), nil
}

// safePathComponent turns an untrusted release selector into a single bounded
// cache-directory name with no path traversal semantics.
func safePathComponent(value string) string {
	replacer := strings.NewReplacer("/", "-", "\\", "-", "..", "-")
	value = strings.Trim(replacer.Replace(value), "- .")
	if value == "" {
		return "latest"
	}
	return value
}
