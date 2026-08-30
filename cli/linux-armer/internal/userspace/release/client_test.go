package release

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestDownloadRequiresExactAssetSetAndChecksums verifies that an exact release
// is downloaded only when API digests and its checksum manifest agree.
func TestDownloadRequiresExactAssetSetAndChecksums(t *testing.T) {
	files := map[string][]byte{
		"payload.tar.xz":   []byte("payload"),
		"evidence.txt":     []byte("evidence"),
		"RELEASE-NOTES.md": []byte("notes"),
	}
	checksums := []byte(fmt.Sprintf("%s  payload.tar.xz\n%s  evidence.txt\n",
		digest(files["payload.tar.xz"]), digest(files["evidence.txt"])))
	files["SHA256SUMS"] = checksums
	server := releaseServer(t, "component-v1", files)
	defer server.Close()

	client := NewClient(server.Client())
	client.APIBaseURL = server.URL
	bundle, err := client.Download(context.Background(), Spec{
		Component: "component", Repository: "owner/repo", Tag: "component-v1",
		ExactAssets:         []string{"SHA256SUMS", "payload.tar.xz", "evidence.txt", "RELEASE-NOTES.md"},
		UnchecksummedAssets: []string{"RELEASE-NOTES.md"},
	}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if len(bundle.Files) != 3 {
		t.Fatalf("files = %d, want checksum plus two verified assets", len(bundle.Files))
	}
	for _, file := range bundle.Files {
		if !file.Verified {
			t.Fatalf("file %s was not verified", file.Name)
		}
	}
	if _, err := os.Stat(filepath.Join(bundle.Directory, "linux-armer-userspace-bundle.json")); err != nil {
		t.Fatal(err)
	}
	receiptData, err := os.ReadFile(filepath.Join(bundle.Directory, "linux-armer-userspace-bundle.json"))
	if err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(strings.NewReader(string(receiptData)))
	decoder.DisallowUnknownFields()
	var receipt Bundle
	if err := decoder.Decode(&receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.Directory != "." {
		t.Fatalf("receipt directory = %q, want portable current directory", receipt.Directory)
	}
	for _, file := range receipt.Files {
		if file.Path != file.Name || filepath.IsAbs(file.Path) {
			t.Fatalf("receipt path for %s is not portable: %q", file.Name, file.Path)
		}
	}
	for _, file := range bundle.Files {
		if !filepath.IsAbs(file.Path) {
			t.Fatalf("live result path for %s is not absolute: %q", file.Name, file.Path)
		}
	}
}

// TestPortableBundleReceiptRejectsMismatchedRuntimePaths verifies that receipt
// publication cannot silently describe a file outside its downloaded bundle.
func TestPortableBundleReceiptRejectsMismatchedRuntimePaths(t *testing.T) {
	directory := t.TempDir()
	_, err := portableBundleReceipt(Bundle{
		Directory: directory,
		Files:     []File{{Name: "payload", Path: filepath.Join(t.TempDir(), "payload")}},
	})
	if err == nil || !strings.Contains(err.Error(), "does not identify payload") {
		t.Fatalf("error = %v", err)
	}
}

// TestDownloadRejectsUnexpectedReleaseAsset verifies that an expanded upstream
// release asset set fails closed instead of downloading unreviewed content.
func TestDownloadRejectsUnexpectedReleaseAsset(t *testing.T) {
	files := map[string][]byte{
		"payload": []byte("payload"),
		"extra":   []byte("extra"),
	}
	files["SHA256SUMS"] = []byte(digest(files["payload"]) + "  payload\n")
	server := releaseServer(t, "component-v1", files)
	defer server.Close()
	client := NewClient(server.Client())
	client.APIBaseURL = server.URL
	_, err := client.Download(context.Background(), Spec{
		Component: "component", Repository: "owner/repo", Tag: "component-v1",
		ExactAssets: []string{"SHA256SUMS", "payload"},
	}, t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "unexpected release asset") {
		t.Fatalf("error = %v", err)
	}
}

// TestDownloadRejectsDigestDisagreement verifies that conflicting GitHub and
// SHA256SUMS evidence prevents publication of a userspace bundle.
func TestDownloadRejectsDigestDisagreement(t *testing.T) {
	files := map[string][]byte{"payload": []byte("payload")}
	files["SHA256SUMS"] = []byte(strings.Repeat("0", 64) + "  payload\n")
	server := releaseServer(t, "component-v1", files)
	defer server.Close()
	client := NewClient(server.Client())
	client.APIBaseURL = server.URL
	_, err := client.Download(context.Background(), Spec{
		Component: "component", Repository: "owner/repo", Tag: "component-v1",
		ExactAssets: []string{"SHA256SUMS", "payload"},
	}, t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "disagree") {
		t.Fatalf("error = %v", err)
	}
}

// TestParseChecksumsRejectsTraversal verifies that checksum entries cannot name
// files outside the flat release bundle directory.
func TestParseChecksumsRejectsTraversal(t *testing.T) {
	path := filepath.Join(t.TempDir(), "SHA256SUMS")
	if err := os.WriteFile(path, []byte(strings.Repeat("a", 64)+"  ../escape\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := parseChecksums(path); err == nil {
		t.Fatal("expected unsafe checksum member to fail")
	}
}

// TestValidateAssetNameUsesCatalogueVocabulary verifies that direct release
// callers cannot bypass the catalogue's conservative portable filename rules.
func TestValidateAssetNameUsesCatalogueVocabulary(t *testing.T) {
	for _, name := range []string{"payload.tar.xz", "libcamera0.7_1.0+sp11_arm64.deb", "SHA256SUMS"} {
		if err := validateAssetName(name); err != nil {
			t.Errorf("validateAssetName(%q) = %v", name, err)
		}
	}
	for _, name := range []string{" leading", "trailing ", "two words", "line\nbreak", "-option", "../payload"} {
		if err := validateAssetName(name); err == nil {
			t.Errorf("validateAssetName(%q) accepted an unsafe name", name)
		}
	}
}

// releaseServer emulates the GitHub release metadata and asset endpoints with
// trustworthy digests derived from the supplied fixture contents.
func releaseServer(t *testing.T, tag string, files map[string][]byte) *httptest.Server {
	t.Helper()
	server := httptest.NewTLSServer(nil)
	server.Config.Handler = http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if strings.HasPrefix(request.URL.Path, "/repos/") {
			assets := make([]Asset, 0, len(files))
			for name, contents := range files {
				assets = append(assets, Asset{
					Name: name, DownloadURL: server.URL + "/assets/" + name,
					Digest: "sha256:" + digest(contents), Size: int64(len(contents)),
				})
			}
			_ = json.NewEncoder(writer).Encode(githubRelease{TagName: tag, Assets: assets})
			return
		}
		name := strings.TrimPrefix(request.URL.Path, "/assets/")
		contents, ok := files[name]
		if !ok {
			http.NotFound(writer, request)
			return
		}
		_, _ = writer.Write(contents)
	})
	return server
}

// digest returns the lowercase SHA-256 encoding used by release fixtures.
func digest(contents []byte) string {
	sum := sha256.Sum256(contents)
	return hex.EncodeToString(sum[:])
}
