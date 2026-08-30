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
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/artifact"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/catalog"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image/companion"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image/ubuntu"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/release"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/plan"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
	userspacecatalog "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/catalog"
	userspacemanager "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/manager"
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
	// ToolCommit identifies the source revision represented by the companion.
	ToolCommit string
	// ToolBuildDate records the CLI build timestamp represented by the companion.
	ToolBuildDate string
	// CompanionSourceDirectory selects the complete linux-armer source tree to
	// archive and cross-build for use from the live medium.
	CompanionSourceDirectory string
	// CompanionUserspace selects verified, redistribution-eligible release bundles
	// to carry for offline installation.
	CompanionUserspace []string
	// UserspaceCatalogPath optionally overrides the embedded userspace catalogue.
	UserspaceCatalogPath string
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
	// Userspace resolves optional verified offline companion releases.
	Userspace *userspacemanager.Manager
	// CompanionRunner probes the host Go toolchain needed only when the caller
	// asks to build a companion executable from source.
	CompanionRunner platform.Runner
}

// imageAdapter is the distribution-neutral planning and execution boundary
// selected from validated catalogue metadata.
type imageAdapter interface {
	// Plan renders the adapter's deterministic workflow without external work.
	Plan(imageAdapterRequest) (plan.Plan, error)
	// Create executes the adapter with already resolved and verified inputs.
	Create(context.Context, imageAdapterRequest) (ubuntu.Result, error)
}

// imageAdapterRequest carries common image inputs across the manager-to-adapter
// boundary without exposing catalogue lookup policy to an adapter.
type imageAdapterRequest struct {
	// Source is a catalogue selector, override, or resolved local artefact path.
	Source string
	// SourceSHA256 is the effective caller or publisher SHA-256 pin.
	SourceSHA256 string
	// Output is the requested published image path.
	Output string
	// Bundle is the planned or fully resolved kernel payload.
	Bundle kernel.Bundle
	// ToolVersion is written into image provenance.
	ToolVersion string
	// Companion describes the optional on-media CLI and support payload.
	Companion companion.BuildRequest
	// CompanionUserspace lists stable component IDs selected for inclusion.
	CompanionUserspace []string
	// WorkspaceRoot optionally selects the temporary workspace parent.
	WorkspaceRoot string
	// KeepWorkspace retains adapter diagnostics when requested.
	KeepWorkspace bool
}

// ubuntuCasperImageAdapter binds the generic manager boundary to the Ubuntu
// Casper implementation selected by catalogue.AdapterUbuntuCasper.
type ubuntuCasperImageAdapter struct {
	// remasterer performs real Ubuntu ISO creation and may be nil for planning.
	remasterer *ubuntu.Remasterer
}

// Plan delegates generic image planning through the selected Ubuntu adapter.
func (a ubuntuCasperImageAdapter) Plan(request imageAdapterRequest) (plan.Plan, error) {
	return ubuntu.BuildPlan(ubuntuAdapterRequest(request))
}

// Create delegates verified inputs through the same Ubuntu adapter selected
// during planning.
func (a ubuntuCasperImageAdapter) Create(ctx context.Context, request imageAdapterRequest) (ubuntu.Result, error) {
	if a.remasterer == nil {
		return ubuntu.Result{}, errors.New("image manager dependencies are incomplete")
	}
	return a.remasterer.Create(ctx, ubuntuAdapterRequest(request))
}

// ubuntuAdapterRequest translates distribution-neutral manager inputs into the
// existing Ubuntu Casper adapter contract in one place.
func ubuntuAdapterRequest(request imageAdapterRequest) ubuntu.Request {
	return ubuntu.Request{
		SourceISO:          request.Source,
		SourceSHA256:       request.SourceSHA256,
		OutputISO:          request.Output,
		Bundle:             request.Bundle,
		ToolVersion:        request.ToolVersion,
		Companion:          request.Companion,
		CompanionUserspace: request.CompanionUserspace,
		WorkspaceRoot:      request.WorkspaceRoot,
		KeepWorkspace:      request.KeepWorkspace,
	}
}

// imageOperation holds one validated catalogue selection and the adapter route
// shared by dry-run planning and real image creation.
type imageOperation struct {
	// request is the defaulted manager request used for input resolution.
	request CreateImageRequest
	// entry is the exact validated catalogue record selected by the caller.
	entry catalog.Entry
	// adapter is the distribution implementation selected from entry.
	adapter imageAdapter
	// adapterRequest contains the common planned inputs for that implementation.
	adapterRequest imageAdapterRequest
}

// NewImageManager constructs an image workflow with production resolvers and a
// caller-provided catalogue loader and progress writer.
func NewImageManager(loader catalog.Loader, out io.Writer) *ImageManager {
	return &ImageManager{
		Catalogs:        loader,
		Artifacts:       artifact.NewResolver(nil),
		Releases:        release.NewClient(nil),
		Remaster:        ubuntu.NewRemasterer(nil, out),
		CompanionRunner: platform.ExecRunner{},
	}
}

// Plan describes the externally visible workflow without downloading or
// mutating anything. The adapter later produces a more detailed execution
// plan after the exact kernel ABI is known.
func (m *ImageManager) Plan(request CreateImageRequest) (plan.Plan, error) {
	operation, err := m.prepareImageOperation(request)
	if err != nil {
		return plan.Plan{}, err
	}
	return operation.adapter.Plan(operation.adapterRequest)
}

// Create resolves and verifies every external input, invokes the supported
// distribution adapter, and returns only after the image is validated and published.
func (m *ImageManager) Create(ctx context.Context, request CreateImageRequest) (CreateImageResult, error) {
	if m.Artifacts == nil || m.Releases == nil || m.Remaster == nil {
		return CreateImageResult{}, errors.New("image manager dependencies are incomplete")
	}
	operation, err := m.prepareImageOperation(request)
	if err != nil {
		return CreateImageResult{}, err
	}
	request = operation.request

	cacheDirectory, err := resolveCacheDirectory(request.CacheDirectory)
	if err != nil {
		return CreateImageResult{}, err
	}
	if err := os.MkdirAll(cacheDirectory, 0o755); err != nil {
		return CreateImageResult{}, fmt.Errorf("create cache directory: %w", err)
	}

	companionRequest, err := m.resolveCompanion(ctx, request, cacheDirectory)
	if err != nil {
		return CreateImageResult{}, err
	}
	bundle, err := m.resolveBundle(ctx, request, cacheDirectory)
	if err != nil {
		return CreateImageResult{}, err
	}
	sourcePath, sourceDigest, err := m.resolveSource(ctx, request, operation.entry, cacheDirectory)
	if err != nil {
		return CreateImageResult{}, err
	}
	adapterRequest := operation.adapterRequest
	adapterRequest.Source = sourcePath
	adapterRequest.SourceSHA256 = sourceDigest
	adapterRequest.Bundle = bundle
	adapterRequest.Companion = companionRequest
	adapterRequest.CompanionUserspace = companionBundleComponentIDs(companionRequest)
	result, err := operation.adapter.Create(ctx, adapterRequest)
	if err != nil {
		return CreateImageResult{}, err
	}
	return CreateImageResult{CatalogEntry: operation.entry, KernelBundle: bundle, Image: result}, nil
}

// prepareImageOperation validates local relationships, resolves one catalogue
// entry, and selects the adapter route used by both Plan and Create.
func (m *ImageManager) prepareImageOperation(request CreateImageRequest) (imageOperation, error) {
	request = imageDefaults(request)
	if strings.TrimSpace(request.Output) == "" {
		return imageOperation{}, errors.New("output ISO path is required")
	}
	componentIDs, err := resolveOfflineCompanionComponentIDs(request.CompanionUserspace)
	if err != nil {
		return imageOperation{}, err
	}
	if strings.TrimSpace(request.CompanionSourceDirectory) == "" && len(componentIDs) != 0 {
		return imageOperation{}, errors.New("companion userspace releases require --companion-source-dir")
	}
	if strings.TrimSpace(request.CompanionSourceDirectory) != "" {
		sourceDirectory, err := filepath.Abs(request.CompanionSourceDirectory)
		if err != nil {
			return imageOperation{}, fmt.Errorf("resolve companion source directory: %w", err)
		}
		if err := validateCompanionGeneratedPaths(request, sourceDirectory); err != nil {
			return imageOperation{}, err
		}
	}

	mediaCatalog, err := m.Catalogs.Load(request.CatalogPath)
	if err != nil {
		return imageOperation{}, err
	}
	entry, ok := mediaCatalog.Get(request.CatalogID)
	if !ok {
		return imageOperation{}, fmt.Errorf("catalog entry %q was not found", request.CatalogID)
	}
	adapter, err := m.adapterForEntry(entry)
	if err != nil {
		return imageOperation{}, err
	}

	kernelInput := request.KernelDirectory
	if kernelInput == "" {
		kernelInput = request.KernelRepository + "@" + request.KernelRelease
	}
	sourceInput := request.Source
	if sourceInput == "" {
		sourceInput = "catalog:" + entry.ID
	}
	return imageOperation{
		request: request,
		entry:   entry,
		adapter: adapter,
		adapterRequest: imageAdapterRequest{
			Source:             sourceInput,
			SourceSHA256:       effectiveSourceSHA256(request, entry),
			Output:             request.Output,
			Bundle:             kernel.Bundle{Release: kernelInput, ABI: "resolved-at-execution"},
			ToolVersion:        request.ToolVersion,
			Companion:          companion.BuildRequest{SourceDirectory: request.CompanionSourceDirectory},
			CompanionUserspace: componentIDs,
			WorkspaceRoot:      request.WorkspaceRoot,
			KeepWorkspace:      request.KeepWorkspace,
		},
	}, nil
}

// adapterForEntry enforces support and format capabilities before returning
// the concrete distribution adapter selected by catalogue metadata.
func (m *ImageManager) adapterForEntry(entry catalog.Entry) (imageAdapter, error) {
	if entry.SupportLevel != catalog.SupportLevelImplemented {
		return nil, fmt.Errorf("catalog entry %q is %s and cannot yet be created", entry.ID, entry.SupportLevel)
	}
	if !catalog.AdapterSupportsArtifact(entry.Adapter, entry.ArtifactKind) {
		return nil, fmt.Errorf("catalog entry %q adapter %q cannot consume artifact kind %q", entry.ID, entry.Adapter, entry.ArtifactKind)
	}
	switch entry.Adapter {
	case catalog.AdapterUbuntuCasper:
		return ubuntuCasperImageAdapter{remasterer: m.Remaster}, nil
	default:
		return nil, fmt.Errorf("catalog entry %q selects unavailable adapter %q", entry.ID, entry.Adapter)
	}
}

// effectiveSourceSHA256 selects an explicit caller pin before a compatible
// publisher checksum so planning and execution describe the same integrity rule.
func effectiveSourceSHA256(request CreateImageRequest, entry catalog.Entry) string {
	expected := strings.ToLower(strings.TrimSpace(request.SourceSHA256))
	if expected == "" && entry.Checksum != nil && strings.EqualFold(entry.Checksum.Algorithm, "sha256") {
		expected = strings.ToLower(entry.Checksum.Value)
	}
	return expected
}

// resolveCompanion prepares generic staging inputs and downloads only explicitly
// selected userspace releases whose validated catalogue policy permits inclusion.
func (m *ImageManager) resolveCompanion(
	ctx context.Context,
	request CreateImageRequest,
	cacheDirectory string,
) (companion.BuildRequest, error) {
	if strings.TrimSpace(request.CompanionSourceDirectory) == "" {
		if len(request.CompanionUserspace) != 0 {
			return companion.BuildRequest{}, errors.New("companion userspace releases require --companion-source-dir")
		}
		return companion.BuildRequest{}, nil
	}
	componentIDs, err := resolveOfflineCompanionComponentIDs(request.CompanionUserspace)
	if err != nil {
		return companion.BuildRequest{}, err
	}
	sourceDirectory, err := filepath.Abs(request.CompanionSourceDirectory)
	if err != nil {
		return companion.BuildRequest{}, fmt.Errorf("resolve companion source directory: %w", err)
	}
	if err := validateCompanionGeneratedPaths(request, sourceDirectory); err != nil {
		return companion.BuildRequest{}, err
	}
	runner := m.CompanionRunner
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	goVersion, err := runner.Capture(ctx, platform.Command{Name: "go", Args: []string{"version"}})
	if err != nil {
		return companion.BuildRequest{}, fmt.Errorf("companion source requires a working Go toolchain on the host: %w", err)
	}
	if !strings.HasPrefix(strings.TrimSpace(string(goVersion)), "go version go") {
		return companion.BuildRequest{}, fmt.Errorf("companion source requires a working Go toolchain on the host: unexpected go version output %q", strings.TrimSpace(string(goVersion)))
	}
	toolCommit, toolBuildDate, err := resolveCompanionToolIdentity(
		ctx, runner, sourceDirectory, request.ToolCommit, request.ToolBuildDate,
	)
	if err != nil {
		return companion.BuildRequest{}, err
	}
	if m.Userspace == nil {
		return companion.BuildRequest{}, errors.New("userspace catalogue manager is unavailable for companion validation")
	}
	componentCatalog, err := m.Userspace.LoadCatalog(request.UserspaceCatalogPath)
	if err != nil {
		return companion.BuildRequest{}, err
	}
	buildRequest := companion.BuildRequest{
		SourceDirectory:  sourceDirectory,
		Version:          request.ToolVersion,
		Commit:           toolCommit,
		BuildDate:        toolBuildDate,
		UserspaceCatalog: componentCatalog,
	}
	if len(componentIDs) == 0 {
		return buildRequest, nil
	}
	for _, componentID := range componentIDs {
		component, ok := componentCatalog.Get(componentID)
		if !ok {
			return companion.BuildRequest{}, fmt.Errorf("userspace component %q is not in the catalog", componentID)
		}
		if component.Redistribution != userspacecatalog.RedistributionAllowed &&
			component.Redistribution != userspacecatalog.RedistributionSourceRequired {
			return companion.BuildRequest{}, fmt.Errorf(
				"userspace component %q has redistribution policy %q and cannot be included offline",
				componentID, component.Redistribution)
		}
	}
	for _, componentID := range componentIDs {
		bundles, err := m.Userspace.Pull(ctx, request.UserspaceCatalogPath, componentID,
			filepath.Join(cacheDirectory, "userspace"))
		if err != nil {
			return companion.BuildRequest{}, fmt.Errorf("resolve offline userspace component %s: %w", componentID, err)
		}
		if len(bundles) != 1 || bundles[0].Component != componentID {
			return companion.BuildRequest{}, fmt.Errorf("userspace component %q resolved an unexpected bundle set", componentID)
		}
		buildRequest.UserspaceBundles = append(buildRequest.UserspaceBundles, bundles[0])
	}
	return buildRequest, nil
}

// resolveOfflineCompanionComponentIDs applies the compiled selector policy
// without loading catalogues or contacting release services.
func resolveOfflineCompanionComponentIDs(selectors []string) ([]string, error) {
	seen := make(map[string]bool, len(selectors))
	componentIDs := make([]string, 0, len(selectors))
	for _, selector := range selectors {
		if strings.EqualFold(strings.TrimSpace(selector), "recommended") {
			return nil, errors.New("offline companion userspace must name each redistribution-eligible component explicitly")
		}
		componentID, err := userspacemanager.ResolveComponentID(selector)
		if err != nil {
			return nil, err
		}
		if componentID != companion.IPTSDOfflineComponentID {
			return nil, fmt.Errorf("userspace component %q is not approved for offline companion inclusion", componentID)
		}
		if seen[componentID] {
			return nil, fmt.Errorf("duplicate companion userspace component %q", componentID)
		}
		seen[componentID] = true
		componentIDs = append(componentIDs, componentID)
	}
	return componentIDs, nil
}

// companionBundleComponentIDs returns the stable component IDs represented by
// already verified bundles for the execution journal's deterministic plan.
func companionBundleComponentIDs(request companion.BuildRequest) []string {
	componentIDs := make([]string, 0, len(request.UserspaceBundles))
	for _, bundle := range request.UserspaceBundles {
		componentIDs = append(componentIDs, bundle.Component)
	}
	return componentIDs
}

// validateCompanionGeneratedPaths keeps outputs, sidecars, and temporary image
// data from changing the source tree before its immutable snapshot is taken.
func validateCompanionGeneratedPaths(request CreateImageRequest, sourceDirectory string) error {
	outputPath, err := filepath.Abs(request.Output)
	if err != nil {
		return fmt.Errorf("resolve companion image output: %w", err)
	}
	if pathIsWithin(outputPath, sourceDirectory) {
		return errors.New("companion image output and its sidecars must be outside --companion-source-dir")
	}
	if strings.TrimSpace(request.WorkspaceRoot) == "" {
		return nil
	}
	workspaceRoot, err := filepath.Abs(request.WorkspaceRoot)
	if err != nil {
		return fmt.Errorf("resolve companion workspace directory: %w", err)
	}
	if pathIsWithin(workspaceRoot, sourceDirectory) {
		return errors.New("--workspace-dir must be outside --companion-source-dir")
	}
	return nil
}

// resolveCompanionToolIdentity fills missing local-build metadata from the
// selected clean Git source rather than mislabelling it as an unknown revision.
func resolveCompanionToolIdentity(
	ctx context.Context,
	runner platform.Runner,
	sourceDirectory string,
	commit string,
	buildDate string,
) (string, string, error) {
	commit = strings.TrimSpace(commit)
	buildDate = strings.TrimSpace(buildDate)
	needsCommit := commit == "" || commit == "unknown"
	needsBuildDate := buildDate == "" || buildDate == "unknown"
	if needsCommit || needsBuildDate {
		revision, err := runner.Capture(ctx, platform.Command{
			Name: "git", Args: []string{"-C", sourceDirectory, "rev-parse", "HEAD"},
		})
		if err != nil {
			return "", "", fmt.Errorf("resolve companion source identity from Git: %w", err)
		}
		resolvedCommit := strings.TrimSpace(string(revision))
		if resolvedCommit == "" || strings.ContainsAny(resolvedCommit, "\r\n") {
			return "", "", errors.New("resolve companion source identity from Git: revision is empty or malformed")
		}
		if needsCommit {
			commit = resolvedCommit
		} else if commit != resolvedCommit {
			return "", "", fmt.Errorf("linux-armer source revision is %s, requested companion commit is %s", resolvedCommit, commit)
		}
		if needsBuildDate {
			commitTime, err := runner.Capture(ctx, platform.Command{
				Name: "git", Args: []string{"-C", sourceDirectory, "show", "-s", "--format=%cI", resolvedCommit},
			})
			if err != nil {
				return "", "", fmt.Errorf("resolve companion source timestamp from Git: %w", err)
			}
			parsed, err := time.Parse(time.RFC3339, strings.TrimSpace(string(commitTime)))
			if err != nil {
				return "", "", fmt.Errorf("parse companion source timestamp from Git: %w", err)
			}
			buildDate = parsed.UTC().Format(time.RFC3339)
		}
		status, err := runner.Capture(ctx, platform.Command{
			Name: "git",
			Args: []string{"-C", sourceDirectory, "status", "--porcelain=v1", "--untracked-files=all", "--", "."},
		})
		if err != nil {
			return "", "", fmt.Errorf("inspect companion source status: %w", err)
		}
		if strings.TrimSpace(string(status)) != "" {
			return "", "", errors.New("git-backed linux-armer source is dirty; commit or remove changes before building a companion image")
		}
	}
	return commit, buildDate, nil
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
	expected := effectiveSourceSHA256(request, entry)
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

// pathIsWithin reports whether candidate is root itself or a lexical descendant
// after both paths have been resolved to absolute, clean host paths.
func pathIsWithin(candidate, root string) bool {
	relative, err := filepath.Rel(root, candidate)
	if err != nil {
		return false
	}
	return relative == "." || relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}
