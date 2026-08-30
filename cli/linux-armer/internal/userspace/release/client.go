// Package release downloads exact, checksum-bound userspace component releases.
package release

import (
	"bufio"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/artifact"
)

// DefaultRepository is the public release source used when a validated spec
// does not provide an explicit GitHub owner and repository.
const DefaultRepository = "ooaklee/linux-surface-pro-11-oe"

// portableAssetNamePattern matches the same conservative flat filename
// vocabulary accepted by the userspace catalogue validator.
var portableAssetNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+~:-]*$`)

// Asset is the security-relevant subset of GitHub release asset metadata used
// to verify name, download location, digest, and byte size.
type Asset struct {
	// Name is the flat release filename checked against the exact allow-list.
	Name string `json:"name"`
	// DownloadURL is the API-provided location from which the artefact is acquired.
	DownloadURL string `json:"browser_download_url"`
	// Digest is GitHub's publisher-side SHA-256 identity for the asset.
	Digest string `json:"digest"`
	// Size is GitHub's recorded byte count, checked after download.
	Size int64 `json:"size"`
}

// githubRelease is the minimal release API response needed to reject draft or
// mismatched releases and enumerate their assets.
type githubRelease struct {
	TagName string  `json:"tag_name"`
	Draft   bool    `json:"draft"`
	Assets  []Asset `json:"assets"`
}

// Spec is a compiled projection of validated catalogue metadata. ExactAssets is
// the complete release asset set. UnchecksummedAssets names non-installable
// evidence such as release notes that the publisher intentionally excludes
// from SHA256SUMS.
type Spec struct {
	// Component identifies the catalogue component represented by the bundle.
	Component string
	// Repository is the GitHub owner and repository; empty selects DefaultRepository.
	Repository string
	// Tag is the immutable release tag requested from GitHub.
	Tag string
	// ExactAssets is the complete release asset set; additions and omissions fail.
	ExactAssets []string
	// UnchecksummedAssets contains non-installable evidence deliberately omitted
	// from SHA256SUMS while remaining part of ExactAssets.
	UnchecksummedAssets []string
}

// File records the local identity and verification result of one acquired bundle
// asset for machine-readable output and later install validation.
type File struct {
	// Name is the release asset's flat filename.
	Name string `json:"name"`
	// Path is absolute in a live download result and is the flat asset name in a
	// portable on-disc receipt.
	Path string `json:"path"`
	// SHA256 is the digest computed for the downloaded bytes.
	SHA256 string `json:"sha256"`
	// Size is the downloaded file's byte count.
	Size int64 `json:"size"`
	// Verified reports whether acquisition matched the required digest.
	Verified bool `json:"verified"`
}

// Bundle describes one complete verified userspace release in its local cache
// directory.
type Bundle struct {
	// Component is the stable userspace catalogue identifier.
	Component string `json:"component"`
	// Repository names the GitHub source used for acquisition.
	Repository string `json:"repository"`
	// Release is the exact downloaded tag.
	Release string `json:"release"`
	// Directory is absolute in a live download result and is "." in a portable
	// on-disc receipt so the bundle can be moved as one directory.
	Directory string `json:"directory"`
	// Files contains the checksum manifest followed by verified payload assets.
	Files []File `json:"files"`
}

// Client queries GitHub release metadata and delegates atomic, digest-checked
// artefact acquisition to the shared resolver.
type Client struct {
	// HTTP performs release API requests and should carry caller timeout policy.
	HTTP *http.Client
	// APIBaseURL allows tests or compatible GitHub endpoints to replace the API root.
	APIBaseURL string
	// Token is an optional GitHub bearer token; it is never written to manifests.
	Token string
	// Artifacts downloads files atomically while enforcing expected SHA-256 values.
	Artifacts *artifact.Resolver
}

// NewClient returns a GitHub release client using the default HTTP client when
// none is supplied and honouring GITHUB_TOKEN for authenticated API access.
func NewClient(httpClient *http.Client) *Client {
	if httpClient == nil {
		httpClient = http.DefaultClient
	}
	return &Client{
		HTTP:       httpClient,
		APIBaseURL: "https://api.github.com",
		Token:      os.Getenv("GITHUB_TOKEN"),
		Artifacts:  artifact.NewResolver(httpClient),
	}
}

// Download acquires exactly the assets named by spec, verifies GitHub digests,
// SHA256SUMS coverage, and byte sizes, then atomically publishes a bundle manifest.
func (c *Client) Download(ctx context.Context, spec Spec, directory string) (Bundle, error) {
	if err := validateSpec(spec); err != nil {
		return Bundle{}, err
	}
	if spec.Repository == "" {
		spec.Repository = DefaultRepository
	}
	selected, err := c.resolve(ctx, spec.Repository, spec.Tag)
	if err != nil {
		return Bundle{}, err
	}
	assets, err := requireExactAssets(selected.Assets, spec.ExactAssets)
	if err != nil {
		return Bundle{}, fmt.Errorf("release %s: %w", spec.Tag, err)
	}
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return Bundle{}, fmt.Errorf("create userspace bundle directory: %w", err)
	}
	absoluteDirectory, err := filepath.Abs(directory)
	if err != nil {
		return Bundle{}, fmt.Errorf("resolve userspace bundle directory: %w", err)
	}

	checksumAsset := assets["SHA256SUMS"]
	checksumDigest, err := githubSHA256(checksumAsset)
	if err != nil {
		return Bundle{}, err
	}
	checksumResult, err := c.Artifacts.Acquire(ctx, artifact.Source{
		Location: checksumAsset.DownloadURL, ExpectedSHA256: checksumDigest,
	}, filepath.Join(absoluteDirectory, "SHA256SUMS"))
	if err != nil {
		return Bundle{}, fmt.Errorf("download checksum manifest: %w", err)
	}
	if checksumResult.Size != checksumAsset.Size {
		return Bundle{}, fmt.Errorf("download checksum manifest: size is %d bytes, GitHub records %d", checksumResult.Size, checksumAsset.Size)
	}
	checksums, err := parseChecksums(checksumResult.Path)
	if err != nil {
		return Bundle{}, err
	}
	if err := validateChecksumCoverage(checksums, spec); err != nil {
		return Bundle{}, err
	}

	files := []File{{
		Name: "SHA256SUMS", Path: checksumResult.Path, SHA256: checksumResult.SHA256,
		Size: checksumResult.Size, Verified: checksumResult.Verified,
	}}
	names := make([]string, 0, len(checksums))
	for name := range checksums {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		assetItem := assets[name]
		githubDigest, err := githubSHA256(assetItem)
		if err != nil {
			return Bundle{}, err
		}
		if githubDigest != checksums[name] {
			return Bundle{}, fmt.Errorf("GitHub digest and SHA256SUMS disagree for %s", name)
		}
		result, err := c.Artifacts.Acquire(ctx, artifact.Source{
			Location: assetItem.DownloadURL, ExpectedSHA256: checksums[name],
		}, filepath.Join(absoluteDirectory, name))
		if err != nil {
			return Bundle{}, fmt.Errorf("download %s: %w", name, err)
		}
		if result.Size != assetItem.Size {
			return Bundle{}, fmt.Errorf("download %s: size is %d bytes, GitHub records %d", name, result.Size, assetItem.Size)
		}
		files = append(files, File{
			Name: name, Path: result.Path, SHA256: result.SHA256,
			Size: result.Size, Verified: result.Verified,
		})
	}
	bundle := Bundle{
		Component: spec.Component, Repository: spec.Repository, Release: spec.Tag,
		Directory: absoluteDirectory, Files: files,
	}
	if err := writeBundleManifest(absoluteDirectory, bundle); err != nil {
		return Bundle{}, err
	}
	return bundle, nil
}

// resolve loads one tagged GitHub release and rejects drafts or a response whose
// tag differs from the requested immutable identity.
func (c *Client) resolve(ctx context.Context, repository, tag string) (githubRelease, error) {
	endpoint := fmt.Sprintf("%s/repos/%s/releases/tags/%s",
		strings.TrimRight(c.APIBaseURL, "/"), repository, url.PathEscape(tag))
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return githubRelease{}, err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	request.Header.Set("User-Agent", "linux-armer")
	if c.Token != "" {
		request.Header.Set("Authorization", "Bearer "+c.Token)
	}
	response, err := c.HTTP.Do(request)
	if err != nil {
		return githubRelease{}, fmt.Errorf("query userspace release: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return githubRelease{}, fmt.Errorf("query userspace release: server returned %s", response.Status)
	}
	var selected githubRelease
	if err := json.NewDecoder(response.Body).Decode(&selected); err != nil {
		return githubRelease{}, fmt.Errorf("decode userspace release: %w", err)
	}
	if selected.Draft {
		return githubRelease{}, fmt.Errorf("release %s is still a draft", tag)
	}
	if selected.TagName != tag {
		return githubRelease{}, fmt.Errorf("release endpoint returned tag %q, expected %q", selected.TagName, tag)
	}
	return selected, nil
}

// validateSpec enforces a flat tag, a complete unique asset set containing
// SHA256SUMS, and a valid subset of intentionally unchecksummed evidence files.
func validateSpec(spec Spec) error {
	if strings.TrimSpace(spec.Component) == "" {
		return errors.New("userspace component is required")
	}
	if strings.TrimSpace(spec.Tag) == "" || strings.ContainsAny(spec.Tag, `/\\`) {
		return errors.New("userspace release tag must be a flat non-empty name")
	}
	if len(spec.ExactAssets) == 0 {
		return errors.New("userspace release exact asset set is required")
	}
	seen := map[string]bool{}
	for _, name := range spec.ExactAssets {
		if err := validateAssetName(name); err != nil {
			return err
		}
		if seen[name] {
			return fmt.Errorf("duplicate exact asset %q", name)
		}
		seen[name] = true
	}
	if !seen["SHA256SUMS"] {
		return errors.New("exact assets must include SHA256SUMS")
	}
	for _, name := range spec.UnchecksummedAssets {
		if name == "SHA256SUMS" || !seen[name] {
			return fmt.Errorf("unchecksummed asset %q is not a permitted release asset", name)
		}
	}
	return nil
}

// requireExactAssets compares the API response with the catalogue allow-list in
// both directions so publisher-side asset additions and omissions both fail.
func requireExactAssets(items []Asset, expected []string) (map[string]Asset, error) {
	want := make(map[string]bool, len(expected))
	for _, name := range expected {
		want[name] = true
	}
	got := make(map[string]Asset, len(items))
	for _, item := range items {
		if err := validateAssetName(item.Name); err != nil {
			return nil, err
		}
		if _, duplicate := got[item.Name]; duplicate {
			return nil, fmt.Errorf("duplicate release asset %q", item.Name)
		}
		if !want[item.Name] {
			return nil, fmt.Errorf("unexpected release asset %q", item.Name)
		}
		got[item.Name] = item
	}
	for name := range want {
		if _, ok := got[name]; !ok {
			return nil, fmt.Errorf("missing release asset %q", name)
		}
	}
	return got, nil
}

// validateChecksumCoverage ensures SHA256SUMS covers every installable asset and
// neither itself nor intentionally unchecksummed evidence.
func validateChecksumCoverage(checksums map[string]string, spec Spec) error {
	unchecksummed := make(map[string]bool, len(spec.UnchecksummedAssets))
	for _, name := range spec.UnchecksummedAssets {
		unchecksummed[name] = true
	}
	want := make(map[string]bool, len(spec.ExactAssets))
	for _, name := range spec.ExactAssets {
		if name != "SHA256SUMS" && !unchecksummed[name] {
			want[name] = true
		}
	}
	for name := range checksums {
		if !want[name] {
			return fmt.Errorf("SHA256SUMS covers unexpected or unchecksummed asset %q", name)
		}
		delete(want, name)
	}
	if len(want) != 0 {
		missing := make([]string, 0, len(want))
		for name := range want {
			missing = append(missing, name)
		}
		sort.Strings(missing)
		return fmt.Errorf("SHA256SUMS does not cover required assets: %s", strings.Join(missing, ", "))
	}
	return nil
}

// parseChecksums reads a strict two-field SHA256SUMS file, rejecting malformed
// digests, unsafe names, duplicates, self-coverage, and empty manifests.
func parseChecksums(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	result := map[string]string{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) != 2 || len(fields[0]) != 64 {
			return nil, fmt.Errorf("malformed SHA256SUMS line %q", scanner.Text())
		}
		if _, err := hex.DecodeString(fields[0]); err != nil {
			return nil, fmt.Errorf("malformed SHA256SUMS digest %q: %w", fields[0], err)
		}
		name := strings.TrimPrefix(fields[1], "*")
		if err := validateAssetName(name); err != nil {
			return nil, fmt.Errorf("unsafe path in SHA256SUMS: %w", err)
		}
		if name == "SHA256SUMS" {
			return nil, errors.New("SHA256SUMS must not cover itself")
		}
		if _, exists := result[name]; exists {
			return nil, fmt.Errorf("duplicate SHA256SUMS entry %q", name)
		}
		result[name] = strings.ToLower(fields[0])
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(result) == 0 {
		return nil, errors.New("SHA256SUMS is empty")
	}
	return result, nil
}

// validateAssetName rejects empty, nested, non-portable, or traversal-like
// release filenames before they can be joined to a cache directory.
func validateAssetName(name string) error {
	if name == "" || strings.TrimSpace(name) != name || filepath.Base(name) != name ||
		name == "." || name == ".." || strings.ContainsAny(name, `/\\`) ||
		!portableAssetNamePattern.MatchString(name) {
		return fmt.Errorf("unsafe release asset name %q", name)
	}
	return nil
}

// githubSHA256 extracts and validates GitHub's sha256-prefixed asset digest.
func githubSHA256(assetItem Asset) (string, error) {
	digest := strings.TrimSpace(strings.ToLower(assetItem.Digest))
	if !strings.HasPrefix(digest, "sha256:") {
		return "", fmt.Errorf("GitHub release asset %s has no SHA-256 digest", assetItem.Name)
	}
	digest = strings.TrimPrefix(digest, "sha256:")
	if len(digest) != 64 {
		return "", fmt.Errorf("GitHub release asset %s has malformed SHA-256 digest", assetItem.Name)
	}
	if _, err := hex.DecodeString(digest); err != nil {
		return "", fmt.Errorf("GitHub release asset %s has malformed SHA-256 digest: %w", assetItem.Name, err)
	}
	return digest, nil
}

// writeBundleManifest records the verified bundle through a same-directory
// temporary file and atomic rename, avoiding partially written metadata.
func writeBundleManifest(directory string, bundle Bundle) error {
	receipt, err := portableBundleReceipt(bundle)
	if err != nil {
		return err
	}
	path := filepath.Join(directory, "linux-armer-userspace-bundle.json")
	file, err := os.CreateTemp(directory, ".linux-armer-userspace-bundle-*.tmp")
	if err != nil {
		return fmt.Errorf("create userspace bundle manifest: %w", err)
	}
	temporary := file.Name()
	if err := file.Chmod(0o644); err != nil {
		_ = file.Close()
		_ = os.Remove(temporary)
		return fmt.Errorf("set userspace bundle manifest permissions: %w", err)
	}
	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	writeErr := encoder.Encode(receipt)
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		_ = os.Remove(temporary)
		return errors.Join(writeErr, closeErr)
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return fmt.Errorf("publish userspace bundle manifest: %w", err)
	}
	return nil
}

// portableBundleReceipt converts a verified in-memory download result into a
// location-independent receipt whose paths are relative to the receipt itself.
func portableBundleReceipt(bundle Bundle) (Bundle, error) {
	if !filepath.IsAbs(bundle.Directory) || filepath.Clean(bundle.Directory) != bundle.Directory {
		return Bundle{}, errors.New("userspace bundle directory must be a canonical absolute path")
	}
	receipt := bundle
	receipt.Directory = "."
	receipt.Files = make([]File, len(bundle.Files))
	seen := make(map[string]bool, len(bundle.Files))
	for index, file := range bundle.Files {
		if err := validateAssetName(file.Name); err != nil {
			return Bundle{}, err
		}
		if seen[file.Name] {
			return Bundle{}, fmt.Errorf("duplicate userspace bundle file %q", file.Name)
		}
		seen[file.Name] = true
		expected := filepath.Join(bundle.Directory, file.Name)
		if !filepath.IsAbs(file.Path) || filepath.Clean(file.Path) != expected {
			return Bundle{}, fmt.Errorf("userspace bundle path does not identify %s in its directory", file.Name)
		}
		receipt.Files[index] = file
		receipt.Files[index].Path = file.Name
	}
	return receipt, nil
}
