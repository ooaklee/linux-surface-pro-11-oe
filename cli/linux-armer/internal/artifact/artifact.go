// Package artifact resolves local and remote immutable build inputs.
package artifact

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// Source identifies an artefact and, when available, the digest that must
// match before the artefact can be used.
type Source struct {
	// Location is either a local path, a file URL, or an HTTPS download URL.
	Location string
	// ExpectedSHA256 pins the artefact to a lowercase or uppercase SHA-256
	// digest. An empty value permits acquisition but leaves it unverified.
	ExpectedSHA256 string
}

// Result records the local artefact produced by an acquisition and the
// integrity information observed while publishing it.
type Result struct {
	// Path is the final, atomically published local filename.
	Path string
	// SHA256 is the computed lowercase digest of the complete file.
	SHA256 string
	// Size is the artefact length in bytes.
	Size int64
	// Verified reports whether SHA256 matched a caller-supplied expected digest.
	Verified bool
}

// Resolver acquires immutable artefacts through a configurable HTTP client.
type Resolver struct {
	// Client performs HTTPS downloads and controls redirects, timeouts, and
	// transport policy.
	Client *http.Client
}

// NewResolver returns a resolver backed by client, or by the process-wide
// default HTTP client when client is nil.
func NewResolver(client *http.Client) *Resolver {
	if client == nil {
		client = http.DefaultClient
	}
	return &Resolver{Client: client}
}

// Acquire copies or downloads source to destination and publishes atomically.
func (r *Resolver) Acquire(ctx context.Context, source Source, destination string) (Result, error) {
	if strings.TrimSpace(source.Location) == "" {
		return Result{}, errors.New("artifact location is required")
	}
	expected := strings.ToLower(strings.TrimSpace(source.ExpectedSHA256))
	if expected != "" {
		if len(expected) != sha256.Size*2 {
			return Result{}, fmt.Errorf("expected SHA-256 must contain 64 hexadecimal characters")
		}
		if _, err := hex.DecodeString(expected); err != nil {
			return Result{}, fmt.Errorf("expected SHA-256 is invalid: %w", err)
		}
	}
	if result, err := inspectExisting(destination, expected); err == nil {
		return result, nil
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return Result{}, fmt.Errorf("create artifact directory: %w", err)
	}
	temporary := destination + ".part"
	_ = os.Remove(temporary)
	out, err := os.OpenFile(temporary, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return Result{}, fmt.Errorf("create temporary artifact: %w", err)
	}
	copyErr := r.copy(ctx, source.Location, out)
	closeErr := out.Close()
	if copyErr != nil {
		_ = os.Remove(temporary)
		return Result{}, copyErr
	}
	if closeErr != nil {
		_ = os.Remove(temporary)
		return Result{}, fmt.Errorf("close temporary artifact: %w", closeErr)
	}
	result, err := inspectExisting(temporary, expected)
	if err != nil {
		_ = os.Remove(temporary)
		return Result{}, err
	}
	if err := os.Rename(temporary, destination); err != nil {
		_ = os.Remove(temporary)
		return Result{}, fmt.Errorf("publish artifact: %w", err)
	}
	result.Path = destination
	return result, nil
}

// copy streams one supported source location into destination without
// publishing a partially written artefact.
func (r *Resolver) copy(ctx context.Context, location string, destination io.Writer) error {
	parsed, err := url.Parse(location)
	if err != nil {
		return fmt.Errorf("parse artifact location: %w", err)
	}
	if parsed.Scheme == "http" || parsed.Scheme == "https" {
		if parsed.Scheme != "https" {
			return errors.New("remote artifact URLs must use HTTPS")
		}
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, location, nil)
		if err != nil {
			return fmt.Errorf("create artifact request: %w", err)
		}
		response, err := r.Client.Do(request)
		if err != nil {
			return fmt.Errorf("download artifact: %w", err)
		}
		defer response.Body.Close()
		if response.StatusCode < 200 || response.StatusCode >= 300 {
			return fmt.Errorf("download artifact: server returned %s", response.Status)
		}
		if response.Request.URL.Scheme != "https" {
			return errors.New("artifact redirect downgraded from HTTPS")
		}
		if _, err := io.Copy(destination, response.Body); err != nil {
			return fmt.Errorf("download artifact body: %w", err)
		}
		return nil
	}
	if parsed.Scheme != "" && parsed.Scheme != "file" {
		return fmt.Errorf("unsupported artifact scheme %q", parsed.Scheme)
	}
	path := location
	if parsed.Scheme == "file" {
		path = parsed.Path
	}
	in, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open local artifact: %w", err)
	}
	defer in.Close()
	if _, err := io.Copy(destination, in); err != nil {
		return fmt.Errorf("copy local artifact: %w", err)
	}
	return nil
}

// inspectExisting hashes a regular file and optionally checks it against an
// expected lowercase SHA-256 digest.
func inspectExisting(path, expected string) (Result, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return Result{}, err
	}
	if !info.Mode().IsRegular() {
		return Result{}, fmt.Errorf("artifact is not a regular file: %s", path)
	}
	digest, err := HashFile(path)
	if err != nil {
		return Result{}, err
	}
	if expected != "" && digest != expected {
		return Result{}, fmt.Errorf("SHA-256 mismatch for %s: expected %s, got %s", path, expected, digest)
	}
	return Result{Path: path, SHA256: digest, Size: info.Size(), Verified: expected != ""}, nil
}

// HashFile returns the lowercase SHA-256 digest of the file at path.
func HashFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("open artifact for hashing: %w", err)
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", fmt.Errorf("hash artifact: %w", err)
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}
