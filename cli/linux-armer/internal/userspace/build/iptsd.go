package build

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
	userspaceiptsd "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/iptsd"
)

// maximumDockerMetadataBytes bounds every programmatically consumed Docker
// response while leaving normal build output attached to the caller's streams.
const maximumDockerMetadataBytes = 16 << 10

// iptsdContainerRecipe is the reviewed build recipe executed only inside the
// selected ARM64 container. The host never evaluates these bytes as a script.
const iptsdContainerRecipe = `
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export TZ=UTC

apt-get update >/dev/null
apt-get install -y --no-install-recommends \
  build-essential ca-certificates file git meson ninja-build pkg-config \
  python3 unzip xz-utils zip >/dev/null

rm -rf /work/source /work/build /out/stage
mkdir -p /work/source /out/stage/bin /out/stage/licenses /out/stage/sources

git clone --filter=blob:none --no-checkout "$IPTSD_REPOSITORY" /work/source >/dev/null 2>&1
git -C /work/source checkout --detach "$IPTSD_COMMIT" >/dev/null 2>&1
test "$(git -C /work/source rev-parse 'HEAD^{commit}')" = "$IPTSD_COMMIT"
test "$(git -C /work/source rev-parse 'HEAD^{tree}')" = "$IPTSD_TREE"

export SOURCE_DATE_EPOCH="$(git -C /work/source show -s --format=%ct HEAD)"
export CXXFLAGS="-ffile-prefix-map=/work/source=/usr/src/iptsd -ffile-prefix-map=/work/build=/usr/src/iptsd-build"

meson setup /work/build /work/source \
  --prefix=/usr/local --bindir=libexec --sysconfdir=/etc --buildtype=release \
  -Doptimization=3 -Dwerror=false -Db_lto=false -Ddebug_tools=[] \
  -Dservice_manager=[] -Dsample_config=false -Dforce_access_checks=true \
  --force-fallback-for=CLI11,eigen3,fmt,INIReader,Microsoft.GSL,spdlog
ninja -C /work/build -j "$JOBS" src/iptsd src/iptsd-check-device

install -m 0755 /work/build/src/iptsd /out/stage/bin/sp11-iptsd
install -m 0755 /work/build/src/iptsd-check-device /out/stage/bin/sp11-iptsd-check-device
install -m 0644 /work/source/LICENSE /out/stage/licenses/LICENSE.iptsd
install -m 0644 /integration/LICENSE.integration /out/stage/licenses/LICENSE.integration
install -m 0644 /work/source/subprojects/CLI11-2.6.1/LICENSE /out/stage/licenses/LICENSE.CLI11
install -m 0644 /work/source/subprojects/GSL-4.2.0/LICENSE /out/stage/licenses/LICENSE.Microsoft-GSL
install -m 0644 /work/source/subprojects/GSL-4.2.0/LICENSE.build /out/stage/licenses/LICENSE.Microsoft-GSL.build
install -m 0644 /work/source/subprojects/eigen-5.0.1/LICENSE /out/stage/licenses/LICENSE.Eigen
install -m 0644 /work/source/subprojects/eigen-5.0.1/LICENSE.build /out/stage/licenses/LICENSE.Eigen.build
for notice in /work/source/subprojects/eigen-5.0.1/COPYING.*; do
  install -m 0644 "$notice" "/out/stage/licenses/COPYING.Eigen.${notice##*.}"
done
install -m 0644 /work/source/subprojects/fmt-12.0.0/LICENSE /out/stage/licenses/LICENSE.fmt
install -m 0644 /work/source/subprojects/fmt-12.0.0/LICENSE.build /out/stage/licenses/LICENSE.fmt.build
install -m 0644 /work/source/subprojects/inih-r62/LICENSE.txt /out/stage/licenses/LICENSE.inih
install -m 0644 /work/source/subprojects/spdlog-1.15.3/LICENSE /out/stage/licenses/LICENSE.spdlog
install -m 0644 /work/source/subprojects/spdlog-1.15.3/LICENSE.build /out/stage/licenses/LICENSE.spdlog.build
install -m 0644 /integration/SOURCE.env /out/stage/SOURCE.env

git -C /work/source archive --format=tar --prefix="iptsd-$IPTSD_COMMIT/" HEAD |
  gzip -n >"/out/stage/sources/iptsd-$IPTSD_COMMIT.tar.gz"
for wrap in cli11 eigen fmt inih microsoft-gsl spdlog; do
  cp "/work/source/subprojects/$wrap.wrap" /out/stage/sources/
done
cp /work/source/subprojects/packagecache/* /out/stage/sources/

gxx_version="$(g++ --version | head -n 1)"
meson_version="$(meson --version)"
ninja_version="$(ninja --version)"
cat > /out/stage/BUILD.env <<EOF
BUILD_IMAGE=$BUILD_IMAGE
BUILD_IMAGE_ID=$BUILD_IMAGE_ID
BUILD_IMAGE_DIGEST=$BUILD_IMAGE_DIGEST
BUILD_ARCH=aarch64
SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
GXX_VERSION=$gxx_version
MESON_VERSION=$meson_version
NINJA_VERSION=$ninja_version
MESON_OPTIONS=--prefix=/usr/local --bindir=libexec --sysconfdir=/etc --buildtype=release -Doptimization=3 -Dwerror=false -Db_lto=false -Ddebug_tools=[] -Dservice_manager=[] -Dsample_config=false -Dforce_access_checks=true --force-fallback-for=CLI11,eigen3,fmt,INIReader,Microsoft.GSL,spdlog
EOF

dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' |
  LC_ALL=C sort > /out/stage/SBOM.dpkg.tsv
{
  for source in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
    [ -f "$source" ] || continue
    printf '### %s\n' "$source"
    sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$source"
  done
} > /out/stage/APT.sources.txt

file /out/stage/bin/sp11-iptsd /out/stage/bin/sp11-iptsd-check-device > /out/stage/FILE.txt
ldd /out/stage/bin/sp11-iptsd |
  sed -E 's/\(0x[[:xdigit:]]+\)/(0xADDR)/g' > /out/stage/LDD.iptsd.txt
ldd /out/stage/bin/sp11-iptsd-check-device |
  sed -E 's/\(0x[[:xdigit:]]+\)/(0xADDR)/g' > /out/stage/LDD.check-device.txt

(
  cd /out/stage
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
  sha256sum -c SHA256SUMS
)
chown -R "$HOST_UID:$HOST_GID" /out/stage
`

// runIPTSD validates immutable integration input, resolves Docker provenance,
// executes the compiled container recipe, then natively validates its output.
func (manager *Manager) runIPTSD(ctx context.Context, root string, request Request) error {
	if request.MinimumFreeGiB != 0 || request.NoPull {
		return errors.New("minimum-free-gib and no-pull apply only to the camera builder")
	}
	image := request.Image
	if image == "" {
		image = userspaceiptsd.DefaultBuildImage
	}
	if !safeDockerReference(image) {
		return errors.New("image must be a bounded Docker reference")
	}
	volume := request.WorkVolume
	if volume == "" {
		volume = userspaceiptsd.DefaultWorkVolume
	}
	if !safeDockerName(volume) {
		return errors.New("work volume must be a safe Docker volume name")
	}
	jobs := request.Jobs
	if jobs == 0 {
		jobs = userspaceiptsd.DefaultJobs
	}
	integration := filepath.Join(root, "userspace", "iptsd-sp11")
	if err := manager.validateIPTSDIntegration(integration); err != nil {
		return fmt.Errorf("validate repository IPTSD integration: %w", err)
	}
	output, err := prepareIPTSDOutput(root, request.OutputDirectory)
	if err != nil {
		return err
	}
	imageID, imageDigest, err := manager.resolveDockerImage(ctx, image)
	if err != nil {
		return err
	}
	if err := manager.ensureDockerVolume(ctx, volume); err != nil {
		return err
	}
	command := iptsdDockerCommand(image, imageID, imageDigest, volume, output, integration, jobs)
	if err := manager.Runner.Run(ctx, command); err != nil {
		return fmt.Errorf("build pinned IPTSD payload: %w", err)
	}
	stage := filepath.Join(output, "stage")
	if err := manager.validateIPTSDPayload(stage, integration); err != nil {
		return fmt.Errorf("validate built IPTSD payload: %w", err)
	}
	return nil
}

// prepareIPTSDOutput creates and resolves the host output directory while
// refusing the release payload directory as a mutable build destination.
func prepareIPTSDOutput(root, configured string) (string, error) {
	output := configured
	if output == "" {
		output = filepath.Join(root, "build", "iptsd-sp11")
	}
	absolute, err := filepath.Abs(output)
	if err != nil {
		return "", fmt.Errorf("resolve IPTSD output directory: %w", err)
	}
	repositoryRoot, err := filepath.Abs(root)
	if err != nil {
		return "", fmt.Errorf("resolve IPTSD repository root: %w", err)
	}
	payloadPath := filepath.Join(repositoryRoot, "payload")
	if absolute == string(filepath.Separator) || absolute == repositoryRoot {
		return "", errors.New("IPTSD build output must be a dedicated subdirectory")
	}
	if withinBuildRoot(payloadPath, absolute) {
		return "", errors.New("IPTSD build output must not be inside the release payload directory")
	}
	if err := os.MkdirAll(absolute, 0o755); err != nil {
		return "", fmt.Errorf("create IPTSD output directory: %w", err)
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return "", fmt.Errorf("resolve IPTSD output directory links: %w", err)
	}
	info, err := os.Lstat(resolved)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", fmt.Errorf("IPTSD output must resolve to a regular directory: %s", resolved)
	}
	payload, err := filepath.EvalSymlinks(payloadPath)
	if err == nil && withinBuildRoot(payload, resolved) {
		return "", errors.New("IPTSD build output must not be inside the release payload directory")
	}
	return filepath.Clean(resolved), nil
}

// withinBuildRoot reports component-aware equality or descent beneath a path.
func withinBuildRoot(root, candidate string) bool {
	relative, err := filepath.Rel(root, candidate)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

// resolveDockerImage pulls a missing ARM64 image and returns its exact ID and
// one repository digest for inclusion in immutable build provenance.
func (manager *Manager) resolveDockerImage(ctx context.Context, image string) (string, string, error) {
	inspect := platform.Command{Name: "docker", Args: []string{"image", "inspect", "--format", "{{.Id}}\n{{join .RepoDigests \",\"}}", image}}
	output, err := manager.captureBounded(ctx, inspect)
	if err != nil {
		if pullErr := manager.Runner.Run(ctx, platform.Command{Name: "docker", Args: []string{"pull", "--platform", "linux/arm64", image}}); pullErr != nil {
			return "", "", fmt.Errorf("pull IPTSD builder image: %w", pullErr)
		}
		output, err = manager.captureBounded(ctx, inspect)
	}
	if err != nil {
		return "", "", fmt.Errorf("inspect IPTSD builder image: %w", err)
	}
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	if len(lines) != 2 || !validDockerSHA(lines[0]) || !validDockerDigest(lines[1]) {
		return "", "", errors.New("Docker returned incomplete or unsafe IPTSD image provenance")
	}
	return lines[0], lines[1], nil
}

// ensureDockerVolume creates the fixed-name Linux work volume only when Docker
// reports that it is absent, then requires a successful exact-name inspection.
func (manager *Manager) ensureDockerVolume(ctx context.Context, volume string) error {
	inspect := platform.Command{Name: "docker", Args: []string{"volume", "inspect", "--format", "{{.Name}}", volume}}
	output, err := manager.captureBounded(ctx, inspect)
	if err != nil {
		if createErr := manager.Runner.Run(ctx, platform.Command{Name: "docker", Args: []string{"volume", "create", volume}}); createErr != nil {
			return fmt.Errorf("create IPTSD Docker work volume: %w", createErr)
		}
		output, err = manager.captureBounded(ctx, inspect)
	}
	if err != nil || strings.TrimSpace(string(output)) != volume {
		return errors.New("Docker did not confirm the exact IPTSD work volume")
	}
	return nil
}

// iptsdDockerCommand assembles the sole container invocation from fixed flags,
// validated names, compiled source pins, and resolved host directories.
func iptsdDockerCommand(image, imageID, imageDigest, volume, output, integration string, jobs int) platform.Command {
	environment := []string{
		"HOST_UID=" + strconv.Itoa(os.Getuid()),
		"HOST_GID=" + strconv.Itoa(os.Getgid()),
		"IPTSD_REPOSITORY=" + userspaceiptsd.SourceRepository,
		"IPTSD_COMMIT=" + userspaceiptsd.SourceCommit,
		"IPTSD_TREE=" + userspaceiptsd.SourceTree,
		"IPTSD_VERSION=" + userspaceiptsd.Version,
		"BUILD_IMAGE=" + image,
		"BUILD_IMAGE_ID=" + imageID,
		"BUILD_IMAGE_DIGEST=" + imageDigest,
		"JOBS=" + strconv.Itoa(jobs),
	}
	args := []string{"run", "--rm", "--platform", "linux/arm64"}
	for _, value := range environment {
		args = append(args, "--env", value)
	}
	args = append(args,
		"--volume", volume+":/work",
		"--volume", output+":/out",
		"--volume", integration+":/integration:ro",
		imageID, "bash", "-ceu", iptsdContainerRecipe,
	)
	return platform.Command{Name: "docker", Args: args}
}

// boundedBuffer retains only a fixed prefix while acknowledging all writes so
// a noisy failed metadata command cannot exhaust process memory or block.
type boundedBuffer struct {
	buffer bytes.Buffer
	limit  int
}

// Write implements io.Writer while discarding bytes beyond the retained bound.
func (writer *boundedBuffer) Write(data []byte) (int, error) {
	remaining := writer.limit - writer.buffer.Len()
	if remaining > 0 {
		_, _ = writer.buffer.Write(data[:min(remaining, len(data))])
	}
	return len(data), nil
}

// Bytes returns a defensive copy of the retained output prefix.
func (writer *boundedBuffer) Bytes() []byte {
	return bytes.Clone(writer.buffer.Bytes())
}

// captureBounded executes one metadata command with bounded standard output
// and error capture, returning a concise failure diagnostic.
func (manager *Manager) captureBounded(ctx context.Context, command platform.Command) ([]byte, error) {
	stdout := &boundedBuffer{limit: maximumDockerMetadataBytes}
	stderr := &boundedBuffer{limit: maximumDockerMetadataBytes}
	command.Stdout = io.Writer(stdout)
	command.Stderr = io.Writer(stderr)
	if err := manager.Runner.Run(ctx, command); err != nil {
		message := strings.TrimSpace(string(stderr.Bytes()))
		if message != "" {
			return nil, fmt.Errorf("%w: %s", err, message)
		}
		return nil, err
	}
	return stdout.Bytes(), nil
}

// safeDockerReference accepts a conservative, bounded reference alphabet and
// rejects flag-like, traversal-like, or whitespace-bearing values.
func safeDockerReference(value string) bool {
	if len(value) == 0 || len(value) > 256 || value[0] == '-' || strings.Contains(value, "..") {
		return false
	}
	for _, character := range value {
		if character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' ||
			character >= '0' && character <= '9' || strings.ContainsRune("./:_@-", character) {
			continue
		}
		return false
	}
	return true
}

// validDockerSHA accepts the exact lowercase sha256 identity form.
func validDockerSHA(value string) bool {
	return strings.HasPrefix(value, "sha256:") && validLowerHex(strings.TrimPrefix(value, "sha256:"), 64)
}

// validDockerDigest accepts exactly one named sha256 repository digest.
func validDockerDigest(value string) bool {
	name, digest, found := strings.Cut(value, "@sha256:")
	return found && safeDockerReference(name) && validLowerHex(digest, 64)
}

// validLowerHex accepts an exact-length lowercase hexadecimal value.
func validLowerHex(value string, length int) bool {
	if len(value) != length {
		return false
	}
	for _, character := range value {
		if character < '0' || character > '9' && character < 'a' || character > 'f' {
			return false
		}
	}
	return true
}
