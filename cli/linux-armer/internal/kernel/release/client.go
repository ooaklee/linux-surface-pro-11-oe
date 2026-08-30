// Package release resolves versioned kernel bundles from GitHub releases.
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
	"sort"
	"strings"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/artifact"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
)

const DefaultRepository = "ooaklee/linux-surface-pro-11-oe"

type Asset struct {
	Name        string `json:"name"`
	DownloadURL string `json:"browser_download_url"`
	Digest      string `json:"digest"`
	Size        int64  `json:"size"`
}

type Release struct {
	TagName     string    `json:"tag_name"`
	Name        string    `json:"name"`
	PublishedAt time.Time `json:"published_at"`
	Draft       bool      `json:"draft"`
	Prerelease  bool      `json:"prerelease"`
	Assets      []Asset   `json:"assets"`
}

type Client struct {
	HTTP       *http.Client
	APIBaseURL string
	Token      string
	Artifacts  *artifact.Resolver
}

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

func (c *Client) List(ctx context.Context, repository string, limit int) ([]Release, error) {
	if repository == "" {
		repository = DefaultRepository
	}
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	endpoint := fmt.Sprintf("%s/repos/%s/releases?per_page=%d", strings.TrimRight(c.APIBaseURL, "/"), repository, limit)
	var releases []Release
	if err := c.getJSON(ctx, endpoint, &releases); err != nil {
		return nil, err
	}
	filtered := releases[:0]
	for _, item := range releases {
		if item.Draft || !hasRuntimePackages(item) {
			continue
		}
		filtered = append(filtered, item)
	}
	return filtered, nil
}

func (c *Client) Resolve(ctx context.Context, repository, ref string) (Release, error) {
	if repository == "" {
		repository = DefaultRepository
	}
	base := fmt.Sprintf("%s/repos/%s/releases", strings.TrimRight(c.APIBaseURL, "/"), repository)
	endpoint := base + "/latest"
	if ref != "" && ref != "latest" {
		endpoint = base + "/tags/" + url.PathEscape(ref)
	}
	var selected Release
	if err := c.getJSON(ctx, endpoint, &selected); err != nil {
		return Release{}, err
	}
	if selected.Draft {
		return Release{}, fmt.Errorf("release %s is still a draft", selected.TagName)
	}
	if !hasRuntimePackages(selected) {
		return Release{}, fmt.Errorf("release %s is not a complete runtime kernel release", selected.TagName)
	}
	return selected, nil
}

func (c *Client) DownloadBundle(ctx context.Context, repository, ref, directory string, includeHeaders bool) (kernel.Bundle, error) {
	selected, err := c.Resolve(ctx, repository, ref)
	if err != nil {
		return kernel.Bundle{}, err
	}
	if repository == "" {
		repository = DefaultRepository
	}
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return kernel.Bundle{}, fmt.Errorf("create kernel bundle directory: %w", err)
	}
	checksumAsset, ok := findAsset(selected, func(name string) bool { return name == "SHA256SUMS" })
	if !ok {
		return kernel.Bundle{}, errors.New("release has no SHA256SUMS asset")
	}
	checksumExpected := assetSHA256(checksumAsset)
	checksumResult, err := c.Artifacts.Acquire(ctx, artifact.Source{
		Location: checksumAsset.DownloadURL, ExpectedSHA256: checksumExpected,
	}, filepath.Join(directory, checksumAsset.Name))
	if err != nil {
		return kernel.Bundle{}, fmt.Errorf("download checksum manifest: %w", err)
	}
	checksums, err := parseChecksums(checksumResult.Path)
	if err != nil {
		return kernel.Bundle{}, err
	}
	var packages []kernel.Package
	for _, asset := range selected.Assets {
		role, _, _, parseErr := kernel.ParsePackageName(asset.Name)
		if parseErr != nil {
			continue
		}
		if !includeHeaders && role != kernel.RoleImage && role != kernel.RoleModules {
			continue
		}
		expected, exists := checksums[asset.Name]
		if !exists {
			return kernel.Bundle{}, fmt.Errorf("SHA256SUMS does not cover %s", asset.Name)
		}
		if githubDigest := assetSHA256(asset); githubDigest != "" && githubDigest != expected {
			return kernel.Bundle{}, fmt.Errorf("GitHub digest and SHA256SUMS disagree for %s", asset.Name)
		}
		result, err := c.Artifacts.Acquire(ctx, artifact.Source{
			Location: asset.DownloadURL, ExpectedSHA256: expected,
		}, filepath.Join(directory, asset.Name))
		if err != nil {
			return kernel.Bundle{}, fmt.Errorf("download %s: %w", asset.Name, err)
		}
		packages = append(packages, kernel.Package{
			Role: role, Name: asset.Name, Path: result.Path, URL: asset.DownloadURL,
			SHA256: result.SHA256, Size: result.Size, Verified: result.Verified,
		})
	}
	bundle, err := kernel.NewBundle(selected.TagName, repository, packages)
	if err != nil {
		return kernel.Bundle{}, err
	}
	manifestPath := filepath.Join(directory, "linux-armer-kernel-bundle.json")
	file, err := os.OpenFile(manifestPath+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return kernel.Bundle{}, fmt.Errorf("create kernel bundle manifest: %w", err)
	}
	writeErr := bundle.WriteJSON(file)
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		_ = os.Remove(manifestPath + ".tmp")
		return kernel.Bundle{}, errors.Join(writeErr, closeErr)
	}
	if err := os.Rename(manifestPath+".tmp", manifestPath); err != nil {
		return kernel.Bundle{}, fmt.Errorf("publish kernel bundle manifest: %w", err)
	}
	return bundle, nil
}

func (c *Client) getJSON(ctx context.Context, endpoint string, destination any) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	request.Header.Set("User-Agent", "linux-armer")
	if c.Token != "" {
		request.Header.Set("Authorization", "Bearer "+c.Token)
	}
	response, err := c.HTTP.Do(request)
	if err != nil {
		return fmt.Errorf("query GitHub releases: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("query GitHub releases: server returned %s", response.Status)
	}
	if err := json.NewDecoder(response.Body).Decode(destination); err != nil {
		return fmt.Errorf("decode GitHub release response: %w", err)
	}
	return nil
}

func hasRuntimePackages(item Release) bool {
	hasImage, hasModules := false, false
	for _, asset := range item.Assets {
		role, _, _, err := kernel.ParsePackageName(asset.Name)
		if err != nil {
			continue
		}
		hasImage = hasImage || role == kernel.RoleImage
		hasModules = hasModules || role == kernel.RoleModules
	}
	return hasImage && hasModules
}

func findAsset(item Release, predicate func(string) bool) (Asset, bool) {
	for _, asset := range item.Assets {
		if predicate(asset.Name) {
			return asset, true
		}
	}
	return Asset{}, false
}

func assetSHA256(asset Asset) string {
	return strings.TrimPrefix(strings.ToLower(asset.Digest), "sha256:")
}

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
		if filepath.Base(name) != name || name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
			return nil, fmt.Errorf("unsafe path in SHA256SUMS: %q", name)
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

func SortByPublished(releases []Release) {
	sort.Slice(releases, func(i, j int) bool { return releases[i].PublishedAt.After(releases[j].PublishedAt) })
}
