// Package manager orchestrates catalogue, release, build, status, and install
// features without placing workflow policy in Cobra commands.
package manager

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	userspacebuild "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/build"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/catalog"
	userspaceinstall "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/install"
	userspacerelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/release"
	userspacestatus "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/status"
)

// Component identifiers bind friendly CLI aliases to validated catalogue entries
// and compiled workflow policy.
const (
	// AudioComponent is the verified FullIO topology and UCM bundle.
	AudioComponent = "audio-fullio-v19c"
	// IPTSDComponent is the verified pen and touchscreen daemon integration.
	IPTSDComponent = "iptsd-v1"
	// CameraComponent is the exact IMX681-enabled libcamera package set.
	CameraComponent = "imx681-libcamera-v1"
)

// recommendedComponents is the deliberately small default pull set; optional
// camera support remains an explicit choice.
var recommendedComponents = []string{AudioComponent, IPTSDComponent}

// statusContract is the compiled side of one catalogue-to-inspector mapping.
// A catalogue override cannot weaken these release safety boundaries by itself.
type statusContract struct {
	id                      string
	feature                 userspacestatus.Feature
	capability              catalog.Capability
	level                   catalog.Level
	minimumGeneration       int
	testedThroughGeneration int
}

// statusContracts cross-check catalogue maturity and kernel compatibility
// before either userspace status delivery consumes those values.
var statusContracts = []statusContract{
	{id: "firmware", feature: userspacestatus.FeatureFirmware, capability: catalog.CapabilityFirmware, level: catalog.LevelRequired},
	{id: "wifi", feature: userspacestatus.FeatureWiFi, capability: catalog.CapabilityNetworking, level: catalog.LevelSupported},
	{id: "bluetooth", feature: userspacestatus.FeatureBluetooth, capability: catalog.CapabilityBluetooth, level: catalog.LevelSupported},
	{id: AudioComponent, feature: userspacestatus.FeatureAudio, capability: catalog.CapabilityAudio, level: catalog.LevelSupported, minimumGeneration: 12, testedThroughGeneration: 19},
	{id: IPTSDComponent, feature: userspacestatus.FeatureIPTSD, capability: catalog.CapabilityPen, level: catalog.LevelSupported, minimumGeneration: 19, testedThroughGeneration: 19},
	{id: "g6-pen", feature: userspacestatus.FeatureG6Pen, capability: catalog.CapabilityPen, level: catalog.LevelDiagnosticOnly},
	{id: "oot-touchscreen", feature: userspacestatus.FeatureTouch, capability: catalog.CapabilityTouchscreen, level: catalog.LevelObsolete},
	{id: CameraComponent, feature: userspacestatus.FeatureCamera, capability: catalog.CapabilityCamera, level: catalog.LevelExperimental, minimumGeneration: 14, testedThroughGeneration: 19},
	{id: "power-profiles", feature: userspacestatus.FeaturePower, capability: catalog.CapabilityPower, level: catalog.LevelSupported},
}

// releaseDownloader is the verified-release capability required by Manager and
// allows orchestration tests to substitute a deterministic implementation.
type releaseDownloader interface {
	// Download acquires one exact release asset set into the requested directory.
	Download(context.Context, userspacerelease.Spec, string) (userspacerelease.Bundle, error)
}

// Installer is the bounded set of component-specific installation workflows
// the userspace manager is permitted to orchestrate.
type Installer interface {
	// Audio installs or plans the immutable FullIO topology and UCM set.
	Audio(context.Context, userspaceinstall.Options) (userspaceinstall.Result, error)
	// IPTSD installs or plans the pinned pen and touchscreen integration.
	IPTSD(context.Context, userspaceinstall.Options) (userspaceinstall.Result, error)
	// Camera installs or plans the exact experimental libcamera package set.
	Camera(context.Context, userspaceinstall.Options) (userspaceinstall.Result, error)
}

// InstallRequest identifies a compiled userspace workflow, its verified input,
// and the explicit filesystem root that may be changed.
type InstallRequest struct {
	// CatalogPath selects an optional strict userspace catalogue override.
	CatalogPath string
	// Selector is audio, iptsd, camera, or the deliberately limited recommended set.
	Selector string
	// From is an exact release directory, or the userspace cache root for recommended.
	From string
	// RepositoryRoot supplies current Git authority for a native camera build or
	// prepared local release. Downloaded immutable bundles do not use it.
	RepositoryRoot string
	// CameraAuthoritySHA256 is the trusted build- or preparation-time digest
	// required when Selector names a native camera input.
	CameraAuthoritySHA256 string
	// Root is the target filesystem root and defaults to the running system root.
	Root string
	// DryRun verifies inputs and returns a plan without changing the target.
	DryRun bool
}

// installTarget binds one catalogue-backed component to its verified release
// directory before dispatching to compiled installer policy.
type installTarget struct {
	component string
	bundleDir string
}

// Manager coordinates catalogue policy with verified downloads, maintained source
// builds, static status inspection, and bounded component installation.
type Manager struct {
	// Loader resolves either the embedded userspace catalogue or an explicit override.
	Loader catalog.Loader
	// Releases downloads exact catalogue-backed release bundles.
	Releases releaseDownloader
	// Builder runs supported component-specific source-build workflows.
	Builder *userspacebuild.Manager
	// Installer applies only the compiled, checksum-bound component workflows.
	Installer Installer
}

// New creates an orchestration manager, supplies production download and build
// implementations when omitted, and always starts with the production installer.
func New(loader catalog.Loader, releases releaseDownloader, builder *userspacebuild.Manager) *Manager {
	if releases == nil {
		releases = userspacerelease.NewClient(nil)
	}
	if builder == nil {
		builder = userspacebuild.New(nil)
	}
	return &Manager{
		Loader: loader, Releases: releases, Builder: builder,
		Installer: userspaceinstall.New(nil),
	}
}

// LoadCatalog loads and validates the embedded catalogue or the requested override
// before any userspace workflow consumes it.
func (m *Manager) LoadCatalog(overridePath string) (*catalog.Catalog, error) {
	if m == nil {
		return nil, errors.New("userspace manager is unavailable")
	}
	return m.Loader.Load(overridePath)
}

// Pull resolves one component or the recommended set through the catalogue, then
// downloads each exact, checksum-bound release into a stable cache location.
func (m *Manager) Pull(ctx context.Context, overridePath, selector, cacheDirectory string) ([]userspacerelease.Bundle, error) {
	componentCatalog, err := m.LoadCatalog(overridePath)
	if err != nil {
		return nil, err
	}
	componentIDs, err := resolveSelector(selector)
	if err != nil {
		return nil, err
	}
	if cacheDirectory == "" {
		userCache, err := os.UserCacheDir()
		if err != nil {
			return nil, fmt.Errorf("resolve user cache directory: %w", err)
		}
		cacheDirectory = filepath.Join(userCache, "linux-armer", "userspace")
	}
	absoluteCache, err := filepath.Abs(cacheDirectory)
	if err != nil {
		return nil, fmt.Errorf("resolve userspace cache directory: %w", err)
	}
	bundles := make([]userspacerelease.Bundle, 0, len(componentIDs))
	for _, componentID := range componentIDs {
		component, ok := componentCatalog.Get(componentID)
		if !ok {
			return nil, fmt.Errorf("userspace component %q is not in the catalog", componentID)
		}
		if !component.SupportActions.Pull || component.Release == nil {
			return nil, fmt.Errorf("userspace component %q does not support verified release pulls", componentID)
		}
		repository, err := releaseRepository(component.Release.URL)
		if err != nil {
			return nil, fmt.Errorf("userspace component %q release URL: %w", componentID, err)
		}
		spec := userspacerelease.Spec{
			Component: component.ID, Repository: repository,
			Tag: component.Release.Tag, ExactAssets: component.Release.AssetAllowlist,
			UnchecksummedAssets: unchecksummedAssets(component.ID),
		}
		destination := filepath.Join(absoluteCache, component.ID, component.Release.Tag)
		bundle, err := m.Releases.Download(ctx, spec, destination)
		if err != nil {
			return nil, fmt.Errorf("pull %s: %w", component.ID, err)
		}
		bundles = append(bundles, bundle)
	}
	return bundles, nil
}

// releaseRepository derives the exact GitHub owner and repository named by
// validated human-facing release metadata so display and download identities
// cannot silently diverge.
func releaseRepository(rawURL string) (string, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return "", fmt.Errorf("parse release URL: %w", err)
	}
	segments := strings.Split(strings.Trim(parsed.Path, "/"), "/")
	if parsed.Scheme != "https" || parsed.Host != "github.com" || len(segments) != 5 ||
		segments[0] == "" || segments[1] == "" || segments[2] != "releases" || segments[3] != "tag" {
		return "", errors.New("must identify an exact github.com OWNER/REPOSITORY release tag")
	}
	return segments[0] + "/" + segments[1], nil
}

// Build delegates one validated userspace source-build request to the build
// manager.
func (m *Manager) Build(ctx context.Context, request userspacebuild.Request) error {
	_, err := m.BuildWithResult(ctx, request)
	return err
}

// BuildWithResult delegates one validated source-build request and preserves
// component-specific structured output for CLI and automation delivery.
func (m *Manager) BuildWithResult(ctx context.Context, request userspacebuild.Request) (userspacebuild.Result, error) {
	if m == nil || m.Builder == nil {
		return userspacebuild.Result{}, errors.New("userspace build manager is unavailable")
	}
	return m.Builder.RunWithResult(ctx, request)
}

// Status inspects an installed or mounted target against the embedded catalogue
// without executing host services or target binaries.
func (m *Manager) Status(options userspacestatus.Options) (userspacestatus.Report, error) {
	return m.StatusWithCatalog("", options)
}

// StatusWithCatalog inspects a target after strictly cross-checking the selected
// catalogue's maturity and kernel boundaries with compiled diagnostic policy.
func (m *Manager) StatusWithCatalog(overridePath string, options userspacestatus.Options) (userspacestatus.Report, error) {
	if m == nil {
		return userspacestatus.Report{}, errors.New("userspace manager is unavailable")
	}
	componentCatalog, err := m.LoadCatalog(overridePath)
	if err != nil {
		return userspacestatus.Report{}, err
	}
	policies, err := makeStatusPolicies(componentCatalog)
	if err != nil {
		return userspacestatus.Report{}, err
	}
	options.ComponentPolicies = policies
	return userspacestatus.Inspect(options)
}

// makeStatusPolicies projects validated catalogue data into the static inspector
// only when every compiled identity, maturity, and compatibility invariant agrees.
func makeStatusPolicies(componentCatalog *catalog.Catalog) ([]userspacestatus.ComponentPolicy, error) {
	if componentCatalog == nil {
		return nil, errors.New("userspace status catalogue is unavailable")
	}
	policies := make([]userspacestatus.ComponentPolicy, 0, len(statusContracts))
	for _, contract := range statusContracts {
		component, found := componentCatalog.Get(contract.id)
		if !found {
			return nil, fmt.Errorf("userspace status catalogue is missing compiled component %q", contract.id)
		}
		if !component.SupportActions.Status {
			return nil, fmt.Errorf("userspace component %q must enable status for the compiled diagnostic", contract.id)
		}
		if component.Capability != contract.capability || component.Level != contract.level {
			return nil, fmt.Errorf("userspace component %q policy disagrees with the compiled diagnostic: capability %s/%s, level %s/%s", contract.id, component.Capability, contract.capability, component.Level, contract.level)
		}
		minimum := 0
		testedThrough := 0
		if component.KernelCompatibility != nil {
			minimum = component.KernelCompatibility.MinimumSP11Generation
			testedThrough = component.KernelCompatibility.TestedThroughSP11Generation
		}
		if minimum != contract.minimumGeneration || testedThrough != contract.testedThroughGeneration {
			return nil, fmt.Errorf("userspace component %q kernel compatibility disagrees with the compiled diagnostic: sp11v%d through sp11v%d, expected sp11v%d through sp11v%d", contract.id, minimum, testedThrough, contract.minimumGeneration, contract.testedThroughGeneration)
		}
		policies = append(policies, userspacestatus.ComponentPolicy{
			ID:                          component.ID,
			Feature:                     contract.feature,
			SupportLevel:                userspacestatus.SupportLevel(component.Level),
			MinimumSP11Generation:       minimum,
			TestedThroughSP11Generation: testedThrough,
		})
	}
	return policies, nil
}

// Install validates catalogue policy, resolves verified component directories,
// and dispatches only the three compiled installers. Camera may additionally
// authenticate a native build or local release against the selected support
// repository. A recommended mutation preflights both downloaded bundles before
// changing either component.
func (m *Manager) Install(ctx context.Context, request InstallRequest) ([]userspaceinstall.Result, error) {
	if m == nil || m.Installer == nil {
		return nil, errors.New("userspace install manager is unavailable")
	}
	componentCatalog, err := m.LoadCatalog(request.CatalogPath)
	if err != nil {
		return nil, err
	}
	components, recommended, err := resolveInstallSelector(request.Selector)
	if err != nil {
		return nil, err
	}
	if request.CameraAuthoritySHA256 != "" && (recommended || len(components) != 1 || components[0] != CameraComponent) {
		return nil, errors.New("camera authority SHA-256 applies only to an explicit camera installation")
	}
	if request.RepositoryRoot != "" && (recommended || len(components) != 1 || components[0] != CameraComponent) {
		return nil, errors.New("repository root applies only to an explicit native camera installation")
	}
	targets, err := resolveInstallTargets(componentCatalog, components, request.From, recommended)
	if err != nil {
		return nil, err
	}

	if request.DryRun {
		return m.runInstalls(ctx, targets, request.Root, request.RepositoryRoot, request.CameraAuthoritySHA256, true)
	}
	if recommended {
		if _, err := m.runInstalls(ctx, targets, request.Root, request.RepositoryRoot, request.CameraAuthoritySHA256, true); err != nil {
			return nil, fmt.Errorf("preflight recommended userspace installation: %w", err)
		}
	}
	return m.runInstalls(ctx, targets, request.Root, request.RepositoryRoot, request.CameraAuthoritySHA256, false)
}

// runInstalls invokes the component-specific installer for each already
// resolved target and returns results in deterministic component order.
func (m *Manager) runInstalls(
	ctx context.Context,
	targets []installTarget,
	root string,
	repositoryRoot string,
	cameraAuthoritySHA256 string,
	dryRun bool,
) ([]userspaceinstall.Result, error) {
	results := make([]userspaceinstall.Result, 0, len(targets))
	for _, target := range targets {
		options := userspaceinstall.Options{
			BundleDir: target.bundleDir, RepositoryRoot: repositoryRoot,
			CameraAuthoritySHA256: cameraAuthoritySHA256,
			Root:                  root, DryRun: dryRun,
		}
		var result userspaceinstall.Result
		var err error
		switch target.component {
		case AudioComponent:
			result, err = m.Installer.Audio(ctx, options)
		case IPTSDComponent:
			result, err = m.Installer.IPTSD(ctx, options)
		case CameraComponent:
			result, err = m.Installer.Camera(ctx, options)
		default:
			err = fmt.Errorf("userspace component %q has no compiled install workflow", target.component)
		}
		if err != nil {
			if result.Component != "" {
				results = append(results, result)
			}
			return results, fmt.Errorf("install %s: %w", target.component, err)
		}
		results = append(results, result)
	}
	return results, nil
}

// resolveInstallSelector accepts only documented installers and marks whether
// the source directory should be interpreted as a userspace cache root.
func resolveInstallSelector(selector string) ([]string, bool, error) {
	if strings.EqualFold(strings.TrimSpace(selector), "recommended") {
		return append([]string(nil), recommendedComponents...), true, nil
	}
	componentID, err := ResolveComponentID(selector)
	if err != nil {
		return nil, false, err
	}
	switch componentID {
	case AudioComponent, IPTSDComponent, CameraComponent:
		return []string{componentID}, false, nil
	default:
		return nil, false, fmt.Errorf("userspace component %q has no compiled install workflow", componentID)
	}
}

// resolveInstallTargets enforces catalogue install capability and converts the
// caller's source into exact release directories without trusting catalogue data
// as executable instructions or writable targets.
func resolveInstallTargets(
	componentCatalog *catalog.Catalog,
	componentIDs []string,
	from string,
	recommended bool,
) ([]installTarget, error) {
	if strings.TrimSpace(from) == "" {
		return nil, errors.New("verified userspace release directory is required; pass --from")
	}
	absoluteFrom, err := filepath.Abs(from)
	if err != nil {
		return nil, fmt.Errorf("resolve userspace release directory: %w", err)
	}
	targets := make([]installTarget, 0, len(componentIDs))
	for _, componentID := range componentIDs {
		component, ok := componentCatalog.Get(componentID)
		if !ok {
			return nil, fmt.Errorf("userspace component %q is not in the catalog", componentID)
		}
		if !component.SupportActions.Install || component.Release == nil {
			return nil, fmt.Errorf("userspace component %q does not support verified installation", componentID)
		}
		bundleDir := absoluteFrom
		if recommended {
			bundleDir = filepath.Join(absoluteFrom, component.ID, component.Release.Tag)
		}
		targets = append(targets, installTarget{component: component.ID, bundleDir: bundleDir})
	}
	return targets, nil
}

// ResolveComponentID maps documented convenience aliases to stable catalogue IDs
// while preserving an unknown non-empty ID for a precise catalogue lookup error.
func ResolveComponentID(value string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "audio", AudioComponent:
		return AudioComponent, nil
	case "iptsd", "pen", IPTSDComponent:
		return IPTSDComponent, nil
	case "camera", CameraComponent:
		return CameraComponent, nil
	default:
		if strings.TrimSpace(value) == "" {
			return "", errors.New("userspace component is required")
		}
		return strings.TrimSpace(value), nil
	}
}

// resolveSelector expands the deliberate recommended set or normalises one
// caller-provided component selector.
func resolveSelector(selector string) ([]string, error) {
	if strings.EqualFold(strings.TrimSpace(selector), "recommended") {
		return append([]string(nil), recommendedComponents...), nil
	}
	componentID, err := ResolveComponentID(selector)
	if err != nil {
		return nil, err
	}
	return []string{componentID}, nil
}

// unchecksummedAssets identifies catalogue-allowlisted, non-installable evidence
// that a publisher intentionally omits from SHA256SUMS.
func unchecksummedAssets(componentID string) []string {
	if componentID == AudioComponent {
		return []string{"RELEASE-NOTES.md"}
	}
	return nil
}
