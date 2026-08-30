// Package ubuntu implements the Ubuntu Casper remaster adapter.
package ubuntu

import (
	"bufio"
	"context"
	"crypto/md5" //nolint:gosec // Ubuntu media compatibility manifest uses MD5.
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/artifact"
	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/plan"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

const AdapterID = "ubuntu-casper"

type Request struct {
	SourceISO     string
	SourceSHA256  string
	OutputISO     string
	Bundle        kernel.Bundle
	ToolVersion   string
	WorkspaceRoot string
	KeepWorkspace bool
}

type Result struct {
	OutputISO     string
	ManifestPath  string
	JournalPath   string
	SHA256        string
	Size          int64
	WorkspacePath string
}

type Remasterer struct {
	Docker *platform.Docker
	Out    io.Writer
}

func NewRemasterer(docker *platform.Docker, out io.Writer) *Remasterer {
	if docker == nil {
		docker = platform.NewDocker(nil)
	}
	if out == nil {
		out = io.Discard
	}
	return &Remasterer{Docker: docker, Out: out}
}

func BuildPlan(request Request) (plan.Plan, error) {
	if request.SourceISO == "" || request.OutputISO == "" {
		return plan.Plan{}, errors.New("source and output ISO paths are required")
	}
	if request.Bundle.ABI == "" {
		return plan.Plan{}, errors.New("kernel bundle ABI is required")
	}
	return plan.New("image.create", []plan.Step{
		{ID: "verify-source", Kind: "verify", Description: "Verify the Ubuntu Casper source ISO", Inputs: map[string]string{"path": request.SourceISO, "sha256": request.SourceSHA256}},
		{ID: "verify-kernel", Kind: "verify", Description: "Verify the version-bound kernel bundle", Inputs: map[string]string{"release": request.Bundle.Release, "abi": request.Bundle.ABI}},
		{ID: "prepare-tools", Kind: "prepare", Description: "Prepare the isolated ARM64 image-tooling container", Inputs: map[string]string{"adapter": AdapterID}},
		{ID: "extract-live-root", Kind: "extract", Description: "Validate and extract the Ubuntu Casper layered filesystems"},
		{ID: "install-kernel", Kind: "kernel", Description: "Install the custom kernel and modules into the live root", Inputs: map[string]string{"abi": request.Bundle.ABI}},
		{ID: "assemble-initramfs-root", Kind: "filesystem", Description: "Apply the standard and live layers to a temporary initramfs build root"},
		{ID: "build-initramfs", Kind: "initramfs", Description: "Generate an initramfs for the exact custom kernel ABI"},
		{ID: "pair-device-trees", Kind: "device-tree", Description: "Extract X1E and X1P Surface Pro 11 DTBs from the same kernel package"},
		{ID: "repack-live-root", Kind: "filesystem", Description: "Repack the modified Casper filesystem"},
		{ID: "replay-hybrid-boot", Kind: "boot", Description: "Replay the source ISO hybrid boot layout and install direct GRUB in both boot paths"},
		{ID: "validate-output", Kind: "verify", Description: "Validate ISO, GPT, ESP, kernel, initramfs, modules, and DTB agreement"},
		{ID: "publish-output", Kind: "publish", Description: "Atomically publish the completed remastered ISO", Inputs: map[string]string{"path": request.OutputISO}},
	}...)
}

func (r *Remasterer) Create(ctx context.Context, request Request) (Result, error) {
	operationPlan, err := BuildPlan(request)
	if err != nil {
		return Result{}, err
	}
	if err := validateBundlePaths(request.Bundle); err != nil {
		return Result{}, err
	}
	if err := r.Docker.Check(ctx); err != nil {
		return Result{}, err
	}
	outputAbsolute, err := filepath.Abs(request.OutputISO)
	if err != nil {
		return Result{}, err
	}
	sourceAbsolute, err := filepath.Abs(request.SourceISO)
	if err != nil {
		return Result{}, err
	}
	if samePath(sourceAbsolute, outputAbsolute) {
		return Result{}, errors.New("source and output ISO paths must be different")
	}
	if err := os.MkdirAll(filepath.Dir(outputAbsolute), 0o755); err != nil {
		return Result{}, fmt.Errorf("create output directory: %w", err)
	}
	workspaceParent := request.WorkspaceRoot
	if workspaceParent == "" {
		workspaceParent = filepath.Dir(outputAbsolute)
	}
	if err := os.MkdirAll(workspaceParent, 0o755); err != nil {
		return Result{}, fmt.Errorf("create workspace root: %w", err)
	}
	workspace, err := os.MkdirTemp(workspaceParent, ".linux-armer-remaster-")
	if err != nil {
		return Result{}, fmt.Errorf("create remaster workspace: %w", err)
	}
	if !request.KeepWorkspace {
		defer os.RemoveAll(workspace)
	}
	journal := plan.NewJournal(operationPlan.Operation)
	journalPath := outputAbsolute + ".journal.json"
	checkpoint := func(step string, digests map[string]string) error {
		journal.Complete(step, digests)
		return journal.Save(journalPath)
	}

	logf(r.Out, "Staging source image and kernel bundle")
	sourcePath := filepath.Join(workspace, "source.iso")
	if err := stageFile(request.SourceISO, sourcePath); err != nil {
		return Result{}, err
	}
	sourceDigest, err := artifact.HashFile(sourcePath)
	if err != nil {
		return Result{}, err
	}
	if request.SourceSHA256 != "" && !strings.EqualFold(request.SourceSHA256, sourceDigest) {
		return Result{}, fmt.Errorf("source ISO SHA-256 mismatch: expected %s, got %s", request.SourceSHA256, sourceDigest)
	}
	if err := checkpoint("verify-source", map[string]string{"source.iso": sourceDigest}); err != nil {
		return Result{}, err
	}
	if err := stageBundle(request.Bundle, workspace); err != nil {
		return Result{}, err
	}
	if err := checkpoint("verify-kernel", packageDigests(request.Bundle)); err != nil {
		return Result{}, err
	}

	logf(r.Out, "Preparing ARM64 image tooling")
	toolsImage, err := r.Docker.EnsureToolsImage(ctx)
	if err != nil {
		return Result{}, err
	}
	if err := checkpoint("prepare-tools", nil); err != nil {
		return Result{}, err
	}

	logf(r.Out, "Extracting Ubuntu Casper live filesystem")
	if err := r.Docker.RunInWorkspace(ctx, toolsImage, workspace,
		"xorriso", "-osirrox", "on", "-indev", "/work/source.iso",
		"-extract", "/casper/install-sources.yaml", "/work/install-sources.yaml",
		"-extract", "/casper/minimal.squashfs", "/work/minimal.squashfs",
		"-extract", "/casper/minimal.standard.squashfs", "/work/minimal.standard.squashfs",
		"-extract", "/casper/minimal.standard.live.squashfs", "/work/minimal.standard.live.squashfs",
		"-extract", "/casper/minimal.manifest", "/work/minimal.manifest",
		"-extract", "/casper/minimal.size", "/work/minimal.size",
		"-extract", "/md5sum.txt", "/work/md5sum.txt",
		"-extract", "/EFI/boot/grubaa64.efi", "/work/grubaa64.efi"); err != nil {
		return Result{}, fmt.Errorf("extract ISO inputs: %w", err)
	}
	if err := validateSourceLayout(workspace); err != nil {
		return Result{}, err
	}
	if err := r.Docker.RunInWorkspace(ctx, toolsImage, workspace,
		"unsquashfs", "-no-xattrs", "-no-progress", "-d", "/work/rootfs", "/work/minimal.squashfs"); err != nil {
		return Result{}, fmt.Errorf("extract Casper filesystem: %w", err)
	}
	// Extraction runs as root in the container. These metadata files are then
	// rewritten by the unprivileged host process, so make that boundary explicit.
	if err := r.Docker.RunInWorkspace(ctx, toolsImage, workspace,
		"chmod", "a+rw", "/work/minimal.manifest", "/work/minimal.size", "/work/md5sum.txt"); err != nil {
		return Result{}, fmt.Errorf("prepare extracted ISO metadata: %w", err)
	}
	if err := checkpoint("extract-live-root", nil); err != nil {
		return Result{}, err
	}

	logf(r.Out, "Installing custom kernel %s into the live filesystem", request.Bundle.ABI)
	for _, pkg := range request.Bundle.Packages {
		if pkg.Role != kernel.RoleImage && pkg.Role != kernel.RoleModules {
			continue
		}
		if err := r.Docker.RunInWorkspace(ctx, toolsImage, workspace,
			"dpkg-deb", "--extract", "/work/kernel/"+pkg.Name, "/work/rootfs"); err != nil {
			return Result{}, fmt.Errorf("extract %s: %w", pkg.Name, err)
		}
	}
	if err := r.Docker.RunInWorkspace(ctx, toolsImage, workspace,
		"depmod", "-a", "-b", "/work/rootfs", request.Bundle.ABI); err != nil {
		return Result{}, fmt.Errorf("index custom kernel modules: %w", err)
	}
	if err := checkpoint("install-kernel", nil); err != nil {
		return Result{}, err
	}

	logf(r.Out, "Assembling the layered Casper root used to generate the live initramfs")
	if err := assembleInitramfsRoot(ctx, r.Docker, toolsImage, workspace, request.Bundle.ABI); err != nil {
		return Result{}, err
	}
	if err := checkpoint("assemble-initramfs-root", nil); err != nil {
		return Result{}, err
	}

	logf(r.Out, "Generating initramfs for %s", request.Bundle.ABI)
	if err := r.Docker.RunInWorkspace(ctx, toolsImage, workspace,
		"chroot", "/work/initramfs-root", "mkinitramfs", "-o", "/boot/initrd.img-"+request.Bundle.ABI, request.Bundle.ABI); err != nil {
		return Result{}, fmt.Errorf("generate custom initramfs: %w", err)
	}
	if err := makeBootArtifactsReadable(ctx, r.Docker, toolsImage, workspace, request.Bundle); err != nil {
		return Result{}, err
	}
	if err := stageBootArtifacts(request.Bundle, workspace); err != nil {
		return Result{}, err
	}
	if err := checkpoint("build-initramfs", nil); err != nil {
		return Result{}, err
	}
	if err := checkpoint("pair-device-trees", nil); err != nil {
		return Result{}, err
	}

	logf(r.Out, "Repacking the Casper live filesystem")
	compression := "xz"
	if details, captureErr := r.Docker.CaptureInWorkspace(ctx, toolsImage, workspace,
		"unsquashfs", "-s", "/work/minimal.squashfs"); captureErr == nil && strings.Contains(strings.ToLower(string(details)), "zstd") {
		compression = "zstd"
	}
	mksquashArgs := []string{"mksquashfs", "/work/rootfs", "/work/remastered.squashfs", "-noappend", "-no-progress", "-comp", compression}
	if compression == "zstd" {
		mksquashArgs = append(mksquashArgs, "-Xcompression-level", "19")
	}
	if err := r.Docker.RunInWorkspace(ctx, toolsImage, workspace, mksquashArgs...); err != nil {
		return Result{}, fmt.Errorf("repack Casper filesystem: %w", err)
	}
	rootSizeOutput, err := r.Docker.CaptureInWorkspace(ctx, toolsImage, workspace,
		"du", "-sx", "--block-size=1", "/work/rootfs")
	if err != nil {
		return Result{}, fmt.Errorf("measure remastered filesystem: %w", err)
	}
	rootSizeFields := strings.Fields(string(rootSizeOutput))
	if len(rootSizeFields) == 0 {
		return Result{}, errors.New("measure remastered filesystem: du returned no size")
	}
	rootSize := rootSizeFields[0]
	if err := os.WriteFile(filepath.Join(workspace, "minimal.size"), []byte(rootSize+"\n"), 0o644); err != nil {
		return Result{}, err
	}
	if err := updatePackageManifest(filepath.Join(workspace, "minimal.manifest"), request.Bundle); err != nil {
		return Result{}, err
	}
	if err := checkpoint("repack-live-root", nil); err != nil {
		return Result{}, err
	}

	bootManifest, err := buildEmbeddedManifest(request, workspace, sourceDigest)
	if err != nil {
		return Result{}, err
	}
	if err := writeSupportFiles(workspace, bootManifest, request.Bundle.ABI); err != nil {
		return Result{}, err
	}
	if err := updateMD5Manifest(workspace); err != nil {
		return Result{}, err
	}

	logf(r.Out, "Replaying the hybrid ISO boot layout")
	partialName := "output.partial.iso"
	xorrisoArgs := []string{
		"xorriso", "-indev", "/work/source.iso", "-outdev", "/work/" + partialName,
		"-boot_image", "any", "replay",
		"-map", "/work/remastered.squashfs", "/casper/minimal.squashfs",
		"-map", "/work/minimal.manifest", "/casper/minimal.manifest",
		"-map", "/work/minimal.size", "/casper/minimal.size",
		"-map", "/work/casper-vmlinuz", "/casper/vmlinuz",
		"-map", "/work/casper-initrd", "/casper/initrd",
		"-map", "/work/grub.cfg", "/boot/grub/grub.cfg",
		"-map", "/work/grubaa64.efi", "/EFI/boot/bootaa64.efi",
		"-map", "/work/sp11", "/sp11",
		"-map", "/work/disk-info", "/.disk/info",
		"-map", "/work/md5sum.txt", "/md5sum.txt",
		"-commit",
	}
	if err := r.Docker.RunInWorkspace(ctx, toolsImage, workspace, xorrisoArgs...); err != nil {
		return Result{}, fmt.Errorf("rebuild hybrid ISO: %w", err)
	}
	if err := replaceAppendedESPBootloader(ctx, r.Docker, toolsImage, workspace, partialName); err != nil {
		return Result{}, err
	}
	if err := checkpoint("replay-hybrid-boot", nil); err != nil {
		return Result{}, err
	}

	partialPath := filepath.Join(workspace, partialName)
	logf(r.Out, "Validating the completed hybrid ISO before publication")
	validation, err := NewValidator(r.Docker).Validate(ctx, partialPath)
	if err != nil {
		return Result{}, fmt.Errorf("validate remastered ISO before publication: %w", err)
	}
	if !validation.Valid {
		return Result{}, errors.New("validate remastered ISO before publication: validator returned an invalid report")
	}
	outputDigest := validation.SHA256
	outputSize := validation.Size
	journal.Output = &plan.OutputRecord{Path: outputAbsolute, SHA256: outputDigest, Size: outputSize}
	if err := checkpoint("validate-output", map[string]string{"output.iso": outputDigest}); err != nil {
		return Result{}, err
	}
	if err := publishFile(partialPath, outputAbsolute); err != nil {
		return Result{}, err
	}
	manifestPath := outputAbsolute + ".manifest.json"
	if err := writeManifest(manifestPath, bootManifest); err != nil {
		return Result{}, err
	}
	if err := checkpoint("publish-output", map[string]string{"output.iso": outputDigest}); err != nil {
		return Result{}, err
	}
	return Result{
		OutputISO: outputAbsolute, ManifestPath: manifestPath, JournalPath: journalPath,
		SHA256: outputDigest, Size: outputSize, WorkspacePath: workspace,
	}, nil
}

func validateBundlePaths(bundle kernel.Bundle) error {
	if !safeKernelABI(bundle.ABI) {
		return fmt.Errorf("kernel bundle ABI %q is not a safe path component", bundle.ABI)
	}
	for _, pkg := range bundle.Packages {
		if pkg.Name == "" || filepath.Base(pkg.Name) != pkg.Name {
			return fmt.Errorf("kernel package name %q is not a safe filename", pkg.Name)
		}
		if pkg.Path == "" {
			continue
		}
		info, err := os.Stat(pkg.Path)
		if err != nil {
			return fmt.Errorf("inspect kernel package %s: %w", pkg.Name, err)
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("kernel package %s is not a regular file", pkg.Name)
		}
		digest, err := artifact.HashFile(pkg.Path)
		if err != nil {
			return fmt.Errorf("verify kernel package %s: %w", pkg.Name, err)
		}
		if !strings.EqualFold(digest, pkg.SHA256) {
			return fmt.Errorf("kernel package %s digest mismatch", pkg.Name)
		}
	}
	for _, role := range []kernel.PackageRole{kernel.RoleImage, kernel.RoleModules} {
		pkg, ok := bundle.Package(role)
		if !ok {
			return fmt.Errorf("kernel bundle has no %s package", role)
		}
		if pkg.Path == "" {
			return fmt.Errorf("kernel bundle %s package has no local path", role)
		}
	}
	requiredTrees := map[string]bool{
		"qcom/x1e80100-microsoft-denali-oled.dtb": false,
		"qcom/x1p64100-microsoft-denali.dtb":      false,
	}
	for _, tree := range bundle.DeviceTrees {
		if strings.Contains(tree.Path, "\\") || filepath.IsAbs(tree.Path) {
			return fmt.Errorf("device tree path %q is not a safe relative path", tree.Path)
		}
		clean := filepath.ToSlash(filepath.Clean(filepath.FromSlash(tree.Path)))
		if clean != tree.Path || clean == "." || strings.HasPrefix(clean, "../") {
			return fmt.Errorf("device tree path %q is not a safe relative path", tree.Path)
		}
		if _, required := requiredTrees[tree.Path]; required {
			requiredTrees[tree.Path] = true
		}
	}
	for tree, present := range requiredTrees {
		if !present {
			return fmt.Errorf("kernel bundle has no required device tree %s", tree)
		}
	}
	return nil
}

func safeKernelABI(abi string) bool {
	if abi == "" || len(abi) > 255 {
		return false
	}
	for _, character := range abi {
		if character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' ||
			character >= '0' && character <= '9' || strings.ContainsRune(".+~_-", character) {
			continue
		}
		return false
	}
	return true
}

func validateSourceLayout(workspace string) error {
	configuration, err := os.ReadFile(filepath.Join(workspace, "install-sources.yaml"))
	if err != nil {
		return fmt.Errorf("validate Ubuntu source layout: read install-sources.yaml: %w", err)
	}
	text := string(configuration)
	for _, required := range []string{
		"default: linux-qcom-x1e",
		"path: minimal.squashfs",
		"path: minimal.standard.squashfs",
		"type: fsimage-layered",
	} {
		if !strings.Contains(text, required) {
			return fmt.Errorf("validate Ubuntu source layout: install-sources.yaml has no %q declaration", required)
		}
	}
	for _, name := range []string{
		"minimal.squashfs",
		"minimal.standard.squashfs",
		"minimal.standard.live.squashfs",
	} {
		info, statErr := os.Stat(filepath.Join(workspace, name))
		if statErr != nil {
			return fmt.Errorf("validate Ubuntu source layout: inspect %s: %w", name, statErr)
		}
		if !info.Mode().IsRegular() || info.Size() == 0 {
			return fmt.Errorf("validate Ubuntu source layout: %s is not a non-empty regular file", name)
		}
	}
	return nil
}

func assembleInitramfsRoot(ctx context.Context, docker *platform.Docker, image, workspace, abi string) error {
	if err := docker.RunInWorkspace(ctx, image, workspace,
		"mkdir", "-p", "/work/initramfs-root", "/work/layers"); err != nil {
		return fmt.Errorf("prepare layered initramfs root: %w", err)
	}
	if err := docker.RunInWorkspace(ctx, image, workspace,
		"cp", "-a", "--reflink=auto", "/work/rootfs/.", "/work/initramfs-root/"); err != nil {
		return fmt.Errorf("copy modified Casper base into initramfs root: %w", err)
	}
	for _, layer := range []struct {
		name string
		file string
	}{
		{name: "standard", file: "minimal.standard.squashfs"},
		{name: "live", file: "minimal.standard.live.squashfs"},
	} {
		layerRoot := "/work/layers/" + layer.name
		if err := docker.RunInWorkspace(ctx, image, workspace,
			"unsquashfs", "-no-xattrs", "-no-progress", "-d", layerRoot, "/work/"+layer.file); err != nil {
			return fmt.Errorf("extract Casper %s layer: %w", layer.name, err)
		}
		if err := applyCasperLayer(ctx, docker, image, workspace, layerRoot, "/work/initramfs-root"); err != nil {
			return fmt.Errorf("apply Casper %s layer: %w", layer.name, err)
		}
	}
	for _, required := range []struct {
		mode string
		path string
	}{
		{mode: "-x", path: "/work/initramfs-root/usr/sbin/mkinitramfs"},
		{mode: "-f", path: "/work/initramfs-root/usr/share/initramfs-tools/hooks/casper"},
		{mode: "-f", path: "/work/initramfs-root/usr/share/initramfs-tools/scripts/casper"},
		{mode: "-s", path: "/work/initramfs-root/usr/lib/modules/" + abi + "/modules.dep"},
	} {
		if err := docker.RunInWorkspace(ctx, image, workspace, "test", required.mode, required.path); err != nil {
			return fmt.Errorf("assembled initramfs root is missing required member %s: %w", required.path, err)
		}
	}
	return nil
}

func applyCasperLayer(ctx context.Context, docker *platform.Docker, image, workspace, layerRoot, targetRoot string) error {
	// Ubuntu's layered squashfs uses overlayfs-style character devices with
	// major/minor 0:0 as whiteouts. Resolve them before copying each upper layer
	// so the chroot matches the live overlay rather than exposing device nodes.
	const script = `layer=$1
target=$2
while IFS= read -r -d '' whiteout; do
  if [ "$(stat -c '%t:%T' "$layer/$whiteout")" != "0:0" ]; then
    continue
  fi
  rm -rf -- "$target/$whiteout"
  rm -f -- "$layer/$whiteout"
done < <(find "$layer" -xdev -type c -printf '%P\0')
cp -a --reflink=auto "$layer/." "$target/"
`
	if err := docker.RunInWorkspace(ctx, image, workspace,
		"bash", "-ceu", script, "linux-armer-layer", layerRoot, targetRoot); err != nil {
		return err
	}
	return nil
}

func stageBundle(bundle kernel.Bundle, workspace string) error {
	directory := filepath.Join(workspace, "kernel")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	for _, pkg := range bundle.Packages {
		if pkg.Path == "" {
			continue
		}
		if err := stageFile(pkg.Path, filepath.Join(directory, pkg.Name)); err != nil {
			return err
		}
	}
	return nil
}

func stageBootArtifacts(bundle kernel.Bundle, workspace string) error {
	root := filepath.Join(workspace, "rootfs")
	kernelSource := filepath.Join(root, "boot", "vmlinuz-"+bundle.ABI)
	initrdSource := filepath.Join(workspace, "initramfs-root", "boot", "initrd.img-"+bundle.ABI)
	if err := stageFile(kernelSource, filepath.Join(workspace, "casper-vmlinuz")); err != nil {
		return fmt.Errorf("stage custom kernel: %w", err)
	}
	if err := stageFile(initrdSource, filepath.Join(workspace, "casper-initrd")); err != nil {
		return fmt.Errorf("stage custom initramfs: %w", err)
	}
	dtbRoot := filepath.Join(workspace, "sp11", "dtb")
	if err := os.MkdirAll(dtbRoot, 0o755); err != nil {
		return err
	}
	for _, dtb := range bundle.DeviceTrees {
		source := filepath.Join(root, "usr", "lib", "firmware", bundle.ABI, "device-tree", filepath.FromSlash(dtb.Path))
		destination := filepath.Join(dtbRoot, filepath.Base(dtb.Path))
		if err := stageFile(source, destination); err != nil {
			return fmt.Errorf("stage %s device tree: %w", dtb.Device, err)
		}
	}
	return nil
}

func makeBootArtifactsReadable(ctx context.Context, docker *platform.Docker, image, workspace string, bundle kernel.Bundle) error {
	paths := []string{
		"/work/rootfs/boot/vmlinuz-" + bundle.ABI,
		"/work/initramfs-root/boot/initrd.img-" + bundle.ABI,
	}
	for _, dtb := range bundle.DeviceTrees {
		paths = append(paths, "/work/rootfs/usr/lib/firmware/"+bundle.ABI+"/device-tree/"+dtb.Path)
	}
	arguments := append([]string{"chmod", "a+r"}, paths...)
	if err := docker.RunInWorkspace(ctx, image, workspace, arguments...); err != nil {
		return fmt.Errorf("make custom boot artifacts readable to the host process: %w", err)
	}
	return nil
}

func buildEmbeddedManifest(request Request, workspace, sourceDigest string) (imagecontract.Manifest, error) {
	sourceInfo, err := os.Stat(filepath.Join(workspace, "source.iso"))
	if err != nil {
		return imagecontract.Manifest{}, err
	}
	kernelRecord, err := artifactRecord(filepath.Join(workspace, "casper-vmlinuz"), "casper/vmlinuz")
	if err != nil {
		return imagecontract.Manifest{}, err
	}
	initrdRecord, err := artifactRecord(filepath.Join(workspace, "casper-initrd"), "casper/initrd")
	if err != nil {
		return imagecontract.Manifest{}, err
	}
	var dtbs []imagecontract.ArtifactRecord
	for _, dtb := range request.Bundle.DeviceTrees {
		record, err := artifactRecord(filepath.Join(workspace, "sp11", "dtb", filepath.Base(dtb.Path)), "sp11/dtb/"+filepath.Base(dtb.Path))
		if err != nil {
			return imagecontract.Manifest{}, err
		}
		dtbs = append(dtbs, record)
	}
	return imagecontract.Manifest{
		SchemaVersion: imagecontract.ManifestSchemaVersion,
		CreatedAt:     time.Now().UTC(),
		ToolVersion:   request.ToolVersion,
		Layout:        "hybrid-iso",
		Adapter:       AdapterID,
		SourceImage: imagecontract.ArtifactRecord{
			Path: "source.iso", SHA256: sourceDigest, Size: sourceInfo.Size(),
		},
		KernelBundle: request.Bundle,
		BootArtifacts: imagecontract.BootArtifactRecord{
			Kernel: kernelRecord, Initrd: initrdRecord, DTBs: dtbs,
		},
		BootArguments: []string{
			"clk_ignore_unused", "pd_ignore_unused", "arm64.nopauth", "systemd.tpm2_wait=0",
			"modprobe.blacklist=qcom_q6v5_pas",
		},
		SecureBoot: "unsupported; disable Secure Boot for the unsigned custom kernel and direct GRUB",
	}, nil
}

func writeSupportFiles(workspace string, manifest imagecontract.Manifest, abi string) error {
	sp11 := filepath.Join(workspace, "sp11")
	if err := os.MkdirAll(filepath.Join(sp11, "kernel"), 0o755); err != nil {
		return err
	}
	for _, pkg := range manifest.KernelBundle.Packages {
		if pkg.Role != kernel.RoleImage && pkg.Role != kernel.RoleModules {
			continue
		}
		if err := stageFile(filepath.Join(workspace, "kernel", pkg.Name), filepath.Join(sp11, "kernel", pkg.Name)); err != nil {
			return err
		}
	}
	if err := writeManifest(filepath.Join(sp11, "linux-armer-manifest.json"), manifest); err != nil {
		return err
	}
	readme := fmt.Sprintf("Linux Armer Surface Pro 11 image\n\nCustom kernel ABI: %s\n\nSecure Boot must be disabled. The USB-safe menu entries temporarily blacklist qcom_q6v5_pas so USB storage remains available in the live session. Kernel packages are included under /sp11/kernel for installed-system setup. Proprietary device firmware is not redistributed.\n", abi)
	if err := os.WriteFile(filepath.Join(sp11, "README.txt"), []byte(readme), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(workspace, "grub.cfg"), []byte(grubConfig(abi)), 0o644); err != nil {
		return err
	}
	diskInfo := fmt.Sprintf("Linux Armer Ubuntu arm64 for Surface Pro 11 (%s)\n", abi)
	return os.WriteFile(filepath.Join(workspace, "disk-info"), []byte(diskInfo), 0o644)
}

func updatePackageManifest(path string, bundle kernel.Bundle) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	var headers []string
	prefix := ""
	if len(lines) >= 2 && strings.HasPrefix(lines[0], "--- ") && strings.HasPrefix(lines[1], "+++ ") {
		headers = append(headers, lines[:2]...)
		lines = lines[2:]
		prefix = "+"
	}
	for _, pkg := range bundle.Packages {
		if pkg.Role != kernel.RoleImage && pkg.Role != kernel.RoleModules {
			continue
		}
		packageName := strings.Split(pkg.Name, "_")[0]
		entry := prefix + packageName + "\t" + bundle.Version
		replaced := false
		for i, line := range lines {
			if strings.HasPrefix(line, prefix+packageName+"\t") {
				lines[i] = entry
				replaced = true
				break
			}
		}
		if !replaced {
			lines = append(lines, entry)
		}
	}
	sort.Strings(lines)
	lines = append(headers, lines...)
	return os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644)
}

func updateMD5Manifest(workspace string) error {
	path := filepath.Join(workspace, "md5sum.txt")
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	entries := map[string]string{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) == 2 {
			entries[fields[1]] = fields[0]
		}
	}
	_ = file.Close()
	if err := scanner.Err(); err != nil {
		return err
	}
	replacements := map[string]string{
		"./casper/minimal.squashfs": "remastered.squashfs",
		"./casper/minimal.manifest": "minimal.manifest",
		"./casper/minimal.size":     "minimal.size",
		"./casper/vmlinuz":          "casper-vmlinuz",
		"./casper/initrd":           "casper-initrd",
		"./boot/grub/grub.cfg":      "grub.cfg",
		"./EFI/boot/bootaa64.efi":   "grubaa64.efi",
		"./.disk/info":              "disk-info",
	}
	err = filepath.WalkDir(filepath.Join(workspace, "sp11"), func(filePath string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			return nil
		}
		relative, relErr := filepath.Rel(workspace, filePath)
		if relErr != nil {
			return relErr
		}
		replacements["./"+filepath.ToSlash(relative)] = relative
		return nil
	})
	if err != nil {
		return err
	}
	for isoPath, localPath := range replacements {
		digest, digestErr := md5File(filepath.Join(workspace, localPath))
		if digestErr != nil {
			return digestErr
		}
		entries[isoPath] = digest
	}
	keys := make([]string, 0, len(entries))
	for key := range entries {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	output, err := os.OpenFile(path+".new", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	for _, key := range keys {
		if _, err := fmt.Fprintf(output, "%s  %s\n", entries[key], key); err != nil {
			_ = output.Close()
			return err
		}
	}
	if err := output.Close(); err != nil {
		return err
	}
	return os.Rename(path+".new", path)
}

func replaceAppendedESPBootloader(ctx context.Context, docker *platform.Docker, image, workspace, outputName string) error {
	report, err := docker.CaptureInWorkspace(ctx, image, workspace,
		"xorriso", "-indev", "/work/"+outputName, "-report_system_area", "plain")
	if err != nil {
		return fmt.Errorf("inspect rebuilt ISO system area: %w", err)
	}
	offset, err := appendedESPOffset(string(report))
	if err != nil {
		return fmt.Errorf("locate appended EFI system partition: %w", err)
	}
	imageSpec := fmt.Sprintf("/work/%s@@%d", outputName, offset)
	// Canonical's appended ESP is only 6 MiB. The source GRUB binary is larger
	// than shim, so reclaim the redundant GRUB copy before replacing BOOTAA64.
	if err := docker.RunInWorkspace(ctx, image, workspace,
		"mdel", "-i", imageSpec, "::/EFI/BOOT/GRUBAA64.EFI"); err != nil {
		return fmt.Errorf("reclaim appended ESP space by removing redundant GRUBAA64.EFI: %w", err)
	}
	if err := docker.RunInWorkspace(ctx, image, workspace,
		"mcopy", "-o", "-i", imageSpec, "/work/grubaa64.efi", "::/EFI/BOOT/BOOTAA64.EFI"); err != nil {
		return fmt.Errorf("install direct GRUB in appended ESP after reclaiming space: %w", err)
	}
	return nil
}

func stageFile(source, destination string) error {
	sourceAbsolute, err := filepath.Abs(source)
	if err != nil {
		return err
	}
	destinationAbsolute, err := filepath.Abs(destination)
	if err != nil {
		return err
	}
	if sourceAbsolute == destinationAbsolute {
		return nil
	}
	sourceInfo, err := os.Stat(sourceAbsolute)
	if err != nil {
		return err
	}
	if !sourceInfo.Mode().IsRegular() {
		return fmt.Errorf("source %q is not a regular file", sourceAbsolute)
	}
	if err := os.MkdirAll(filepath.Dir(destinationAbsolute), 0o755); err != nil {
		return err
	}
	_ = os.Remove(destinationAbsolute)
	if linkInfo, lstatErr := os.Lstat(sourceAbsolute); lstatErr != nil {
		return lstatErr
	} else if linkInfo.Mode()&os.ModeSymlink == 0 {
		if err := os.Link(sourceAbsolute, destinationAbsolute); err == nil {
			return nil
		}
	}
	in, err := os.Open(sourceAbsolute)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(destinationAbsolute, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, in)
	closeErr := out.Close()
	if err := errors.Join(copyErr, closeErr); err != nil {
		_ = os.Remove(destinationAbsolute)
		return err
	}
	return nil
}

func samePath(first, second string) bool {
	if filepath.Clean(first) == filepath.Clean(second) {
		return true
	}
	firstInfo, firstErr := os.Stat(first)
	secondInfo, secondErr := os.Stat(second)
	return firstErr == nil && secondErr == nil && os.SameFile(firstInfo, secondInfo)
}

func publishFile(source, destination string) error {
	temporary := destination + ".partial"
	_ = os.Remove(temporary)
	if err := stageFile(source, temporary); err != nil {
		return fmt.Errorf("stage final output: %w", err)
	}
	if err := os.Rename(temporary, destination); err != nil {
		return fmt.Errorf("publish final output: %w", err)
	}
	return nil
}

func writeManifest(path string, manifest imagecontract.Manifest) error {
	file, err := os.OpenFile(path+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	writeErr := manifest.WriteJSON(file)
	closeErr := file.Close()
	if err := errors.Join(writeErr, closeErr); err != nil {
		_ = os.Remove(path + ".tmp")
		return err
	}
	return os.Rename(path+".tmp", path)
}

func artifactRecord(path, logicalPath string) (imagecontract.ArtifactRecord, error) {
	digest, err := artifact.HashFile(path)
	if err != nil {
		return imagecontract.ArtifactRecord{}, err
	}
	info, err := os.Stat(path)
	if err != nil {
		return imagecontract.ArtifactRecord{}, err
	}
	return imagecontract.ArtifactRecord{Path: logicalPath, SHA256: digest, Size: info.Size()}, nil
}

func packageDigests(bundle kernel.Bundle) map[string]string {
	digests := make(map[string]string, len(bundle.Packages))
	for _, pkg := range bundle.Packages {
		digests[pkg.Name] = pkg.SHA256
	}
	return digests
}

func md5File(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := md5.New() //nolint:gosec // Required by Ubuntu's md5sum.txt format.
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func logf(w io.Writer, format string, args ...any) {
	_, _ = fmt.Fprintf(w, "linux-armer: "+format+"\n", args...)
}
