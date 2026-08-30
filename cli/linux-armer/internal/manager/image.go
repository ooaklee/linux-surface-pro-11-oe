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

const DefaultCatalogID = "ubuntu-concept-resolute-x1e"

type CreateImageRequest struct {
	CatalogPath      string
	CatalogID        string
	Source           string
	SourceSHA256     string
	RefreshSource    bool
	KernelDirectory  string
	KernelRepository string
	KernelRelease    string
	CacheDirectory   string
	WorkspaceRoot    string
	Output           string
	KeepWorkspace    bool
	ToolVersion      string
}

type CreateImageResult struct {
	CatalogEntry catalog.Entry
	KernelBundle kernel.Bundle
	Image        ubuntu.Result
}

type ImageManager struct {
	Catalogs  catalog.Loader
	Artifacts *artifact.Resolver
	Releases  *release.Client
	Remaster  *ubuntu.Remasterer
}

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

func safePathComponent(value string) string {
	replacer := strings.NewReplacer("/", "-", "\\", "-", "..", "-")
	value = strings.Trim(replacer.Replace(value), "- .")
	if value == "" {
		return "latest"
	}
	return value
}
