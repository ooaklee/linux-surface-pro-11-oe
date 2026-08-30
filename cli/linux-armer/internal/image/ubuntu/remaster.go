// Package ubuntu implements the Ubuntu Casper remaster adapter.
package ubuntu

import (
	"bufio"
	"bytes"
	"context"
	"crypto/md5" //nolint:gosec // Ubuntu media compatibility manifest uses MD5.
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/artifact"
	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image/companion"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image/ubuntu/caspermedia"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/plan"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// AdapterID is the stable manifest and catalogue identifier for the Ubuntu
// Casper remaster implementation.
const AdapterID = "ubuntu-casper"

// portableISONameExpression accepts the bounded release-compatible basename
// subset used for newly created installation images.
var portableISONameExpression = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+~%-]{0,199}$`)

// Request contains all verified inputs and output policy for one Ubuntu image
// remaster operation.
type Request struct {
	// SourceISO is the local ARM64 Ubuntu ISO to remaster.
	SourceISO string
	// SourceSHA256 optionally pins SourceISO to an expected digest.
	SourceSHA256 string
	// OutputISO is the destination published only after validation succeeds.
	OutputISO string
	// Bundle is the complete, version-bound kernel and device-tree payload.
	Bundle kernel.Bundle
	// ToolVersion is written into the embedded provenance manifest.
	ToolVersion string
	// Companion describes an optional generic CLI, source, catalogue, and
	// userspace payload to stage under the ISO support directory.
	Companion companion.BuildRequest
	// CompanionUserspace lists stable component IDs selected for the dry-run or
	// execution plan without coupling the adapter to manager aliases.
	CompanionUserspace []string
	// WorkspaceRoot optionally selects the parent for host-side temporary files.
	WorkspaceRoot string
	// KeepWorkspace retains diagnostic host and Docker workspaces after a failure
	// or successful build instead of cleaning them automatically.
	KeepWorkspace bool
}

// Result identifies every durable artefact produced by a successful remaster
// and any diagnostic workspace explicitly retained by the caller.
type Result struct {
	// OutputISO is the absolute path of the atomically published image.
	OutputISO string
	// ManifestPath is the sidecar provenance manifest path.
	ManifestPath string
	// JournalPath is the durable operation checkpoint journal path.
	JournalPath string
	// SHA256 is the digest of the published image.
	SHA256 string
	// Size is the published image length in bytes.
	Size int64
	// WorkspacePath is populated only when host diagnostics were retained.
	WorkspacePath string
	// WorkspaceVolume is populated only when the case-sensitive Docker work
	// volume was retained for diagnostics.
	WorkspaceVolume string
	// CompanionBundle repeats the single manifest's optional support inventory
	// so command callers can report its inclusion and licence status directly.
	CompanionBundle imagecontract.CompanionBundleRecord
}

// Remasterer coordinates host artefact handling with isolated Linux image
// tooling. Callers may inject Docker and output dependencies for testing.
type Remasterer struct {
	// Docker provides the isolated, case-sensitive execution environment.
	Docker *platform.Docker
	// Out receives concise progress messages and may safely be io.Discard.
	Out io.Writer
	// Companions prepares optional distribution-neutral on-media support files.
	Companions *companion.Builder
}

// NewRemasterer creates an Ubuntu remaster adapter, supplying safe default
// dependencies when Docker or the progress writer is nil.
func NewRemasterer(docker *platform.Docker, out io.Writer) *Remasterer {
	if docker == nil {
		docker = platform.NewDocker(nil)
	}
	if out == nil {
		out = io.Discard
	}
	return &Remasterer{Docker: docker, Out: out, Companions: companion.NewBuilder(nil)}
}

// BuildPlan validates the minimum request identity and returns the ordered,
// serialisable steps that Create will execute.
func BuildPlan(request Request) (plan.Plan, error) {
	if request.SourceISO == "" || request.OutputISO == "" {
		return plan.Plan{}, errors.New("source and output ISO paths are required")
	}
	if !validPortableISOOutput(request.OutputISO) {
		return plan.Plan{}, errors.New("output ISO must have a bounded portable .iso filename")
	}
	if request.Bundle.ABI == "" {
		return plan.Plan{}, errors.New("kernel bundle ABI is required")
	}
	companionSource := "not-requested"
	if request.Companion.SourceDirectory != "" {
		companionSource = request.Companion.SourceDirectory
	}
	companionUserspace := "none"
	if len(request.CompanionUserspace) != 0 {
		companionUserspace = strings.Join(request.CompanionUserspace, ",")
	}
	return plan.New("image.create", []plan.Step{
		{ID: "verify-source", Kind: "verify", Description: "Verify the Ubuntu Casper source ISO", Inputs: map[string]string{"path": request.SourceISO, "sha256": request.SourceSHA256}},
		{ID: "verify-kernel", Kind: "verify", Description: "Verify the version-bound kernel bundle", Inputs: map[string]string{"release": request.Bundle.Release, "abi": request.Bundle.ABI}},
		{ID: "stage-companion", Kind: "companion", Description: "Stage the optional Linux ARM64 CLI, corresponding source, catalogues, and eligible userspace releases", Inputs: map[string]string{"source": companionSource, "userspace": companionUserspace}},
		{ID: "prepare-tools", Kind: "prepare", Description: "Prepare the isolated ARM64 image-tooling container", Inputs: map[string]string{"adapter": AdapterID}},
		{ID: "extract-live-root", Kind: "extract", Description: "Validate and extract the Ubuntu Casper layered filesystems"},
		{ID: "install-kernel", Kind: "kernel", Description: "Register the custom kernel and modules in the live and installed-system root", Inputs: map[string]string{"abi": request.Bundle.ABI}},
		{ID: "assemble-initramfs-root", Kind: "filesystem", Description: "Apply the standard and live layers to a temporary initramfs build root"},
		{ID: "build-initramfs", Kind: "initramfs", Description: "Generate an initramfs for the exact custom kernel ABI"},
		{ID: "bind-live-media", Kind: "boot", Description: "Synchronise the generated Casper UUID with the direct ISO medium"},
		{ID: "pair-device-trees", Kind: "device-tree", Description: "Extract X1E and X1P Surface Pro 11 DTBs from the same kernel package"},
		{ID: "repack-live-root", Kind: "filesystem", Description: "Repack the modified Casper filesystem"},
		{ID: "replay-hybrid-boot", Kind: "boot", Description: "Replay the source ISO hybrid boot layout and install direct GRUB in both boot paths"},
		{ID: "validate-output", Kind: "verify", Description: "Validate live-media and installed-system kernel, initramfs, GRUB, and DTB agreement"},
		{ID: "publish-output", Kind: "publish", Description: "Exclusively publish the completed ISO, single manifest sidecar, and execution journal", Inputs: map[string]string{"path": request.OutputISO}},
	}...)
}

// Create remasters, structurally validates, and transactionally publishes an
// Ubuntu hybrid ISO with its single manifest sidecar and execution journal.
// Temporary Linux filesystem work occurs in a case-sensitive Docker volume, and
// no final output is published unless every validation check passes.
func (r *Remasterer) Create(ctx context.Context, request Request) (result Result, returnErr error) {
	operationPlan, err := BuildPlan(request)
	if err != nil {
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
	for _, destination := range []struct {
		path  string
		label string
	}{
		{path: outputAbsolute, label: "output ISO"},
		{path: outputAbsolute + ".manifest.json", label: "manifest sidecar"},
		{path: outputAbsolute + ".journal.json", label: "execution journal"},
	} {
		if err := requireAbsentPublicationPath(destination.path, destination.label); err != nil {
			return Result{}, err
		}
	}
	if err := validateBundlePaths(request.Bundle); err != nil {
		return Result{}, err
	}
	if err := r.Docker.Check(ctx); err != nil {
		return Result{}, err
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
	workingJournalPath := filepath.Join(workspace, "image-create.journal.json")
	checkpoint := func(step string, digests map[string]string) error {
		journal.Complete(step, digests)
		return journal.Save(workingJournalPath)
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
	if err := stageInstalledSupportFiles(workspace, request.Bundle.ABI); err != nil {
		return Result{}, err
	}
	if err := checkpoint("verify-kernel", packageDigests(request.Bundle)); err != nil {
		return Result{}, err
	}
	companionRecord := companion.Absent(companion.OmissionReasonNotRequested)
	if request.Companion.SourceDirectory != "" {
		if r.Companions == nil {
			return Result{}, errors.New("companion builder is unavailable")
		}
		logf(r.Out, "Staging the Linux ARM64 companion bundle")
		companionRequest := request.Companion
		companionRequest.DestinationDirectory = workspace
		companionRecord, err = r.Companions.Build(ctx, companionRequest)
		if err != nil {
			return Result{}, fmt.Errorf("stage companion bundle: %w", err)
		}
	}
	if err := checkpoint("stage-companion", companionDigests(companionRecord)); err != nil {
		return Result{}, err
	}

	logf(r.Out, "Preparing ARM64 image tooling")
	toolsImage, err := r.Docker.EnsureToolsImage(ctx)
	if err != nil {
		return Result{}, err
	}
	workVolume, err := r.Docker.CreateWorkVolume(ctx)
	if err != nil {
		return Result{}, err
	}
	removeWorkVolume := func() error {
		cleanupContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		return r.Docker.RemoveWorkVolume(cleanupContext, workVolume)
	}
	defer func() {
		if returnErr == nil || workVolume == "" {
			return
		}
		if request.KeepWorkspace {
			returnErr = fmt.Errorf("%w (diagnostic Docker volume retained: %s)", returnErr, workVolume)
			return
		}
		if cleanupErr := removeWorkVolume(); cleanupErr != nil {
			returnErr = errors.Join(returnErr,
				fmt.Errorf("temporary Docker volume retained after cleanup failure: %s: %w", workVolume, cleanupErr))
			return
		}
		removedVolume := workVolume
		workVolume = ""
		returnErr = fmt.Errorf("%w (temporary Docker volume removed: %s)", returnErr, removedVolume)
	}()
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
		"-extract", "/.disk/casper-uuid-generic", "/work/source-casper-uuid-generic",
		"-extract", "/EFI/boot/grubaa64.efi", "/work/grubaa64.efi"); err != nil {
		return Result{}, fmt.Errorf("extract ISO inputs: %w", err)
	}
	if err := validateSourceLayout(workspace); err != nil {
		return Result{}, err
	}
	if err := extractCasperFilesystem(ctx, r.Docker, toolsImage, workspace, workVolume,
		"/work/minimal.squashfs", "/linux-work/rootfs"); err != nil {
		return Result{}, fmt.Errorf("extract Casper filesystem: %w", err)
	}
	// Extraction runs as root in the container. These metadata files are then
	// rewritten by the unprivileged host process, so make that boundary explicit.
	if err := r.Docker.RunInWorkspace(ctx, toolsImage, workspace,
		"chmod", "a+rw", "/work/minimal.manifest", "/work/minimal.size", "/work/md5sum.txt", "/work/source-casper-uuid-generic"); err != nil {
		return Result{}, fmt.Errorf("prepare extracted ISO metadata: %w", err)
	}
	if err := checkpoint("extract-live-root", nil); err != nil {
		return Result{}, err
	}

	logf(r.Out, "Registering custom kernel %s in the live filesystem", request.Bundle.ABI)
	if err := installKernelPackages(ctx, r.Docker, toolsImage, workspace, workVolume, request.Bundle); err != nil {
		return Result{}, err
	}
	if err := r.Docker.RunInWorkspaceVolume(ctx, toolsImage, workspace, workVolume,
		"depmod", "-a", "-b", "/linux-work/rootfs", request.Bundle.ABI); err != nil {
		return Result{}, fmt.Errorf("index custom kernel modules: %w", err)
	}
	logf(r.Out, "Installing deterministic X1E/X1P support for the installed system")
	if err := installInstalledSystemSupport(ctx, r.Docker, toolsImage, workspace, workVolume, request.Bundle); err != nil {
		return Result{}, err
	}
	if err := checkpoint("install-kernel", nil); err != nil {
		return Result{}, err
	}

	logf(r.Out, "Assembling the layered Casper root used to generate the live initramfs")
	if err := assembleInitramfsRoot(ctx, r.Docker, toolsImage, workspace, workVolume, request.Bundle.ABI); err != nil {
		return Result{}, err
	}
	if err := checkpoint("assemble-initramfs-root", nil); err != nil {
		return Result{}, err
	}

	logf(r.Out, "Generating initramfs for %s", request.Bundle.ABI)
	if err := r.Docker.RunInWorkspaceVolume(ctx, toolsImage, workspace, workVolume,
		"chroot", "/linux-work/initramfs-root", "mkinitramfs", "-o", "/boot/initrd.img-"+request.Bundle.ABI, request.Bundle.ABI); err != nil {
		return Result{}, fmt.Errorf("generate custom initramfs: %w", err)
	}
	if err := copyBootArtifactsToWorkspace(ctx, r.Docker, toolsImage, workspace, workVolume, request.Bundle); err != nil {
		return Result{}, err
	}
	if err := checkpoint("build-initramfs", nil); err != nil {
		return Result{}, err
	}
	if _, err := stageCasperMediaIdentity(ctx, r.Docker, toolsImage, workspace); err != nil {
		return Result{}, err
	}
	if err := checkpoint("bind-live-media", nil); err != nil {
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
	mksquashArgs := []string{"mksquashfs", "/linux-work/rootfs", "/linux-work/remastered.squashfs", "-noappend", "-no-progress", "-comp", compression}
	if compression == "zstd" {
		mksquashArgs = append(mksquashArgs, "-Xcompression-level", "19")
	}
	if err := r.Docker.RunInWorkspaceVolume(ctx, toolsImage, workspace, workVolume, mksquashArgs...); err != nil {
		return Result{}, fmt.Errorf("repack Casper filesystem: %w", err)
	}
	rootSizeOutput, err := r.Docker.CaptureInWorkspaceVolume(ctx, toolsImage, workspace, workVolume,
		"du", "-sx", "--block-size=1", "/linux-work/rootfs")
	if err != nil {
		return Result{}, fmt.Errorf("measure remastered filesystem: %w", err)
	}
	rootSizeFields := strings.Fields(string(rootSizeOutput))
	if len(rootSizeFields) == 0 {
		return Result{}, errors.New("measure remastered filesystem: du returned no size")
	}
	rootSize := rootSizeFields[0]
	if err := r.Docker.RunInWorkspaceVolume(ctx, toolsImage, workspace, workVolume,
		"cp", "/linux-work/remastered.squashfs", "/work/remastered.squashfs"); err != nil {
		return Result{}, fmt.Errorf("copy remastered Casper filesystem to host workspace: %w", err)
	}
	if err := r.Docker.RunInWorkspace(ctx, toolsImage, workspace,
		"chmod", "a+r", "/work/remastered.squashfs"); err != nil {
		return Result{}, fmt.Errorf("make remastered Casper filesystem readable: %w", err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "minimal.size"), []byte(rootSize+"\n"), 0o644); err != nil {
		return Result{}, err
	}
	if err := updatePackageManifest(filepath.Join(workspace, "minimal.manifest"), request.Bundle); err != nil {
		return Result{}, err
	}
	if err := checkpoint("repack-live-root", nil); err != nil {
		return Result{}, err
	}

	bootManifest, err := buildEmbeddedManifest(request, workspace, sourceDigest, companionRecord)
	if err != nil {
		return Result{}, err
	}
	manifestBytes, err := serialiseManifest(bootManifest)
	if err != nil {
		return Result{}, err
	}
	if err := writeSupportFiles(workspace, bootManifest, manifestBytes, request.Bundle.ABI); err != nil {
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
		"-map", "/work/casper-uuid-generic", "/.disk/casper-uuid-generic",
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
	manifestIdentity := identifyPublicationBytes(manifestBytes)
	if validation.ManifestSHA256 != manifestIdentity.digest || validation.ManifestSize != manifestIdentity.size {
		return Result{}, errors.New("validate remastered ISO before publication: embedded manifest bytes differ from the staged sidecar")
	}
	outputDigest := validation.SHA256
	outputSize := validation.Size
	journal.Output = &plan.OutputRecord{Path: outputAbsolute, SHA256: outputDigest, Size: outputSize}
	if err := checkpoint("validate-output", map[string]string{"output.iso": outputDigest}); err != nil {
		return Result{}, err
	}
	publicationJournal := *journal
	publicationJournal.Records = append([]plan.StepRecord(nil), journal.Records...)
	publicationJournal.Complete("publish-output", map[string]string{"output.iso": outputDigest})
	publicationJournalPath := filepath.Join(workspace, "image-create.complete.journal.json")
	if err := publicationJournal.Save(publicationJournalPath); err != nil {
		return Result{}, fmt.Errorf("stage completed image journal: %w", err)
	}
	journalBytes, err := os.ReadFile(publicationJournalPath)
	if err != nil {
		return Result{}, fmt.Errorf("read completed image journal: %w", err)
	}
	journalIdentity := identifyPublicationBytes(journalBytes)
	manifestPath, journalPath, err := publishImageOutputs(
		partialPath,
		outputAbsolute,
		manifestBytes,
		journalBytes,
		publicationIdentity{digest: outputDigest, size: outputSize},
		manifestIdentity,
		journalIdentity,
		nil,
	)
	if err != nil {
		return Result{}, err
	}
	resultWorkspace := ""
	resultVolume := ""
	if request.KeepWorkspace {
		resultWorkspace = workspace
		resultVolume = workVolume
		logf(r.Out, "Preserving diagnostic workspace %s and Docker volume %s", workspace, workVolume)
	} else {
		if err := removeWorkVolume(); err != nil {
			return Result{}, fmt.Errorf("remove completed build workspace volume: %w", err)
		}
		workVolume = ""
	}
	return Result{
		OutputISO: outputAbsolute, ManifestPath: manifestPath, JournalPath: journalPath,
		SHA256: outputDigest, Size: outputSize, WorkspacePath: resultWorkspace, WorkspaceVolume: resultVolume,
		CompanionBundle: companionRecord,
	}, nil
}

// validateBundlePaths proves that package inputs and device-tree paths are safe,
// regular, digest-matched files before any of them enters a container command.
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

// safeKernelABI reports whether an ABI can be embedded in filesystem paths and
// shell arguments without separators or control characters.
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

// validateSourceLayout rejects Ubuntu media whose layered Casper declaration or
// required filesystem members do not match the adapter's supported contract.
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
	marker, err := os.ReadFile(filepath.Join(workspace, "source-casper-uuid-generic"))
	if err != nil {
		return fmt.Errorf("validate Ubuntu source layout: read Casper media UUID: %w", err)
	}
	if _, err := caspermedia.ParseUUID(marker); err != nil {
		return fmt.Errorf("validate Ubuntu source layout: %w", err)
	}
	return nil
}

// extractCasperFilesystem expands one SquashFS into the case-sensitive Docker
// volume while excluding overlay whiteouts and Docker-incompatible trusted xattrs.
func extractCasperFilesystem(ctx context.Context, docker *platform.Docker, image, workspace, volume, source, destination string) error {
	const script = `source=$1
destination=$2
whiteouts=$(mktemp)
unsquashfs -lln "$source" | awk '$1 ~ /^c/ && $3 == "0," && $4 == "0" { marker="squashfs-root/"; start=index($0, marker); if (start > 0) print substr($0, start + length(marker)) }' > "$whiteouts"
unsquashfs -no-progress -xattrs-exclude '^trusted\.' -exclude-file "$whiteouts" -d "$destination" "$source"
`
	if err := docker.RunInWorkspaceVolume(ctx, image, workspace, volume,
		"bash", "-ceu", script, "linux-armer-extract", source, destination); err != nil {
		return err
	}
	return nil
}

// assembleInitramfsRoot overlays Ubuntu's standard and live layers onto the
// modified base root and verifies the exact tools needed to generate an initramfs.
func assembleInitramfsRoot(ctx context.Context, docker *platform.Docker, image, workspace, volume, abi string) error {
	if err := docker.RunInWorkspaceVolume(ctx, image, workspace, volume,
		"mkdir", "-p", "/linux-work/initramfs-root", "/linux-work/layers"); err != nil {
		return fmt.Errorf("prepare layered initramfs root: %w", err)
	}
	if err := docker.RunInWorkspaceVolume(ctx, image, workspace, volume,
		"cp", "-a", "--reflink=auto", "/linux-work/rootfs/.", "/linux-work/initramfs-root/"); err != nil {
		return fmt.Errorf("copy modified Casper base into initramfs root: %w", err)
	}
	for _, layer := range []struct {
		name string
		file string
	}{
		{name: "standard", file: "minimal.standard.squashfs"},
		{name: "live", file: "minimal.standard.live.squashfs"},
	} {
		layerRoot := "/linux-work/layers/" + layer.name
		if err := applyCasperLayer(ctx, docker, image, workspace, volume,
			"/work/"+layer.file, layerRoot, "/linux-work/initramfs-root"); err != nil {
			return fmt.Errorf("apply Casper %s layer: %w", layer.name, err)
		}
	}
	for _, required := range []struct {
		mode string
		path string
	}{
		{mode: "-x", path: "/linux-work/initramfs-root/usr/sbin/mkinitramfs"},
		{mode: "-f", path: "/linux-work/initramfs-root/usr/share/initramfs-tools/hooks/casper"},
		{mode: "-f", path: "/linux-work/initramfs-root/usr/share/initramfs-tools/scripts/casper"},
		{mode: "-s", path: "/linux-work/initramfs-root/usr/lib/modules/" + abi + "/modules.dep"},
	} {
		if err := docker.RunInWorkspaceVolume(ctx, image, workspace, volume, "test", required.mode, required.path); err != nil {
			return fmt.Errorf("assembled initramfs root is missing required member %s: %w", required.path, err)
		}
	}
	return nil
}

// applyCasperLayer applies one overlay-style SquashFS layer to a target root,
// honouring safe whiteout deletions before copying the remaining Linux metadata.
func applyCasperLayer(ctx context.Context, docker *platform.Docker, image, workspace, volume, source, layerRoot, targetRoot string) error {
	// Ubuntu's layered squashfs uses overlayfs-style character devices with
	// major/minor 0:0 as whiteouts. Exclude those special inodes during
	// extraction, apply their deletions, then copy the remaining Linux layer.
	const script = `source=$1
layer=$2
target=$3
whiteouts=$(mktemp)
unsquashfs -lln "$source" | awk '$1 ~ /^c/ && $3 == "0," && $4 == "0" { marker="squashfs-root/"; start=index($0, marker); if (start > 0) print substr($0, start + length(marker)) }' > "$whiteouts"
unsquashfs -no-progress -xattrs-exclude '^trusted\.' -exclude-file "$whiteouts" -d "$layer" "$source"
while IFS= read -r whiteout; do
	case "$whiteout" in
		""|/*|../*|*/../*) exit 64 ;;
	esac
	rm -rf -- "$target/$whiteout"
done < "$whiteouts"
cp -a --reflink=auto "$layer/." "$target/"
`
	if err := docker.RunInWorkspaceVolume(ctx, image, workspace, volume,
		"bash", "-ceu", script, "linux-armer-layer", source, layerRoot, targetRoot); err != nil {
		return err
	}
	return nil
}

// stageBundle copies or hard-links every local kernel package into the bounded
// host workspace passed to the image-tooling container.
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

// copyBootArtifactsToWorkspace exports the generated kernel, initramfs, and
// paired device trees from the Linux volume to files used by ISO reconstruction.
func copyBootArtifactsToWorkspace(ctx context.Context, docker *platform.Docker, image, workspace, volume string, bundle kernel.Bundle) error {
	const script = `while [ "$#" -gt 0 ]; do
source=$1
destination=$2
shift 2
mkdir -p "$(dirname "$destination")"
cp "$source" "$destination"
chmod a+r "$destination"
done
`
	arguments := []string{
		"bash", "-ceu", script, "linux-armer-copy-boot",
		"/linux-work/rootfs/boot/vmlinuz-" + bundle.ABI, "/work/casper-vmlinuz",
		"/linux-work/initramfs-root/boot/initrd.img-" + bundle.ABI, "/work/casper-initrd",
	}
	for _, dtb := range bundle.DeviceTrees {
		arguments = append(arguments,
			"/linux-work/rootfs/usr/lib/firmware/"+bundle.ABI+"/device-tree/"+dtb.Path,
			"/work/sp11/dtb/"+filepath.Base(dtb.Path),
		)
	}
	if err := docker.RunInWorkspaceVolume(ctx, image, workspace, volume, arguments...); err != nil {
		return fmt.Errorf("copy custom kernel, initramfs, and device trees to host workspace: %w", err)
	}
	return nil
}

// stageCasperMediaIdentity extracts the UUID generated by Ubuntu's initramfs
// hook, validates it, and stages the matching marker for the direct ISO.
func stageCasperMediaIdentity(ctx context.Context, docker *platform.Docker, image, workspace string) (caspermedia.Contract, error) {
	const script = `unpacked=/work/casper-initrd-unpacked
rm -rf "$unpacked"
unmkinitramfs /work/casper-initrd "$unpacked"
cat "$unpacked/main/conf/uuid.conf"
`
	identity, err := docker.CaptureInWorkspace(ctx, image, workspace,
		"bash", "-ceu", script, "linux-armer-casper-identity")
	if err != nil {
		return caspermedia.Contract{}, fmt.Errorf("extract generated Casper media UUID: %w", err)
	}
	contract, err := caspermedia.NewDirectHybrid(identity)
	if err != nil {
		return caspermedia.Contract{}, fmt.Errorf("validate generated Casper media UUID: %w", err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "casper-uuid-generic"), []byte(contract.UUID+"\n"), 0o644); err != nil {
		return caspermedia.Contract{}, fmt.Errorf("stage generated Casper media UUID: %w", err)
	}
	return contract, nil
}

// buildEmbeddedManifest hashes the staged boot payload and combines it with
// source and kernel provenance for inclusion in the completed image.
func buildEmbeddedManifest(
	request Request,
	workspace string,
	sourceDigest string,
	companionRecord imagecontract.CompanionBundleRecord,
) (imagecontract.Manifest, error) {
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
	mediaIdentityRecord, err := artifactRecord(
		filepath.Join(workspace, "casper-uuid-generic"), caspermedia.MediumIdentityPath)
	if err != nil {
		return imagecontract.Manifest{}, err
	}
	mediaIdentity, err := os.ReadFile(filepath.Join(workspace, "casper-uuid-generic"))
	if err != nil {
		return imagecontract.Manifest{}, err
	}
	mediaContract, err := caspermedia.NewDirectHybrid(mediaIdentity)
	if err != nil {
		return imagecontract.Manifest{}, err
	}
	mediaDiscovery, err := mediaContract.DiscoveryRecord(mediaIdentityRecord)
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
		KernelBundle: portableKernelBundle(request.Bundle),
		BootArtifacts: imagecontract.BootArtifactRecord{
			Kernel: kernelRecord, Initrd: initrdRecord, DTBs: dtbs,
		},
		MediaDiscovery:  mediaDiscovery,
		CompanionBundle: companionRecord,
		BootArguments: []string{
			"clk_ignore_unused", "pd_ignore_unused", "arm64.nopauth", "systemd.tpm2_wait=0",
			"soundwire_qcom.sp11_feedback_active_offset2_zero=1",
			"modprobe.blacklist=qcom_q6v5_pas",
		},
		SecureBoot: "unsupported; disable Secure Boot for the unsigned custom kernel and direct GRUB",
	}, nil
}

// portableKernelBundle removes host filesystem paths before publishing kernel
// provenance. Runtime packages point at their location on the ISO, while
// build-only packages carry no path because they are not copied onto the media.
func portableKernelBundle(bundle kernel.Bundle) kernel.Bundle {
	portable := bundle
	portable.Packages = append([]kernel.Package(nil), bundle.Packages...)
	portable.DeviceTrees = append([]kernel.DeviceTree(nil), bundle.DeviceTrees...)
	for index := range portable.Packages {
		pkg := &portable.Packages[index]
		if pkg.Role == kernel.RoleImage || pkg.Role == kernel.RoleModules {
			pkg.Path = "sp11/kernel/" + pkg.Name
		} else {
			pkg.Path = ""
		}
	}
	return portable
}

// writeSupportFiles stages reinstallable kernel packages, provenance, operator
// notes, disk identity, and the device-specific GRUB configuration under the ISO tree.
func writeSupportFiles(workspace string, manifest imagecontract.Manifest, manifestBytes []byte, abi string) error {
	expectedManifestBytes, err := serialiseManifest(manifest)
	if err != nil {
		return err
	}
	if !bytes.Equal(manifestBytes, expectedManifestBytes) {
		return errors.New("embedded manifest bytes differ from their manifest value")
	}
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
	if err := writeNewSyncedFile(filepath.Join(sp11, "linux-armer-manifest.json"), manifestBytes, 0o644); err != nil {
		return err
	}
	companionNote := "No companion CLI bundle was requested for this image."
	if manifest.CompanionBundle.Included {
		companionNote = "A Linux ARM64 linux-armer companion, corresponding source, catalogues, and any declared offline userspace releases are under /sp11/companion. Copy the executable to a writable filesystem before running privileged install operations."
	}
	readme := fmt.Sprintf("Linux Armer Surface Pro 11 image\n\nCustom kernel ABI: %s\n\nSecure Boot must be disabled. The USB-safe menu entries temporarily blacklist qcom_q6v5_pas so USB storage remains available in the live session. Kernel packages are included under /sp11/kernel for installed-system setup. Proprietary device firmware is not redistributed.\n\n%s\n", abi, companionNote)
	if err := os.WriteFile(filepath.Join(sp11, "README.txt"), []byte(readme), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(workspace, "grub.cfg"), []byte(grubConfig(abi)), 0o644); err != nil {
		return err
	}
	diskInfo := fmt.Sprintf("Linux Armer Ubuntu arm64 for Surface Pro 11 (%s)\n", abi)
	return os.WriteFile(filepath.Join(workspace, "disk-info"), []byte(diskInfo), 0o644)
}

// companionDigests converts the complete single-manifest companion inventory
// into journal checkpoint evidence without introducing a second manifest.
func companionDigests(record imagecontract.CompanionBundleRecord) map[string]string {
	digests := make(map[string]string)
	for _, artifactRecord := range companion.FlattenArtifacts(record) {
		digests[artifactRecord.Path] = artifactRecord.SHA256
	}
	return digests
}

// updatePackageManifest replaces or appends the custom kernel package versions
// while preserving Ubuntu's optional two-line manifest diff header.
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

// updateMD5Manifest recalculates Ubuntu's compatibility checksum list for every
// ISO member changed or added by the remaster operation.
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
		"./casper/minimal.squashfs":   "remastered.squashfs",
		"./casper/minimal.manifest":   "minimal.manifest",
		"./casper/minimal.size":       "minimal.size",
		"./casper/vmlinuz":            "casper-vmlinuz",
		"./casper/initrd":             "casper-initrd",
		"./.disk/casper-uuid-generic": "casper-uuid-generic",
		"./boot/grub/grub.cfg":        "grub.cfg",
		"./EFI/boot/bootaa64.efi":     "grubaa64.efi",
		"./.disk/info":                "disk-info",
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

// replaceAppendedESPBootloader installs direct GRUB in the replayed EFI system
// partition after removing the redundant binary needed to make space safely.
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

// stageFile places one regular file at a destination, preferring a hard link and
// falling back to a copy while removing partial copies on failure.
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

// samePath reports whether two paths name the same filesystem object, including
// distinct hard-link or symlink spellings that resolve to the same file.
func samePath(first, second string) bool {
	if filepath.Clean(first) == filepath.Clean(second) {
		return true
	}
	firstInfo, firstErr := os.Stat(first)
	secondInfo, secondErr := os.Stat(second)
	return firstErr == nil && secondErr == nil && os.SameFile(firstInfo, secondInfo)
}

// validPortableISOOutput reports whether an output path has one bounded,
// release-compatible ISO basename without host-specific separator bytes.
func validPortableISOOutput(output string) bool {
	name := filepath.Base(filepath.Clean(output))
	return portableISONameExpression.MatchString(name) &&
		strings.HasSuffix(strings.ToLower(name), ".iso") &&
		!strings.ContainsAny(name, `/\`)
}

// serialiseManifest produces the exact bounded JSON bytes shared by the
// embedded image member and its publication sidecar.
func serialiseManifest(manifest imagecontract.Manifest) ([]byte, error) {
	var output bytes.Buffer
	if err := manifest.WriteJSON(&output); err != nil {
		return nil, fmt.Errorf("serialise image manifest: %w", err)
	}
	if output.Len() == 0 || output.Len() > imagecontract.MaximumManifestSize {
		return nil, fmt.Errorf("serialised image manifest is outside its %d-byte limit", imagecontract.MaximumManifestSize)
	}
	return output.Bytes(), nil
}

// writeNewSyncedFile writes and flushes one ordinary file without following or
// replacing any filesystem object planted at its requested path.
func writeNewSyncedFile(path string, data []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(data)
	syncErr := file.Sync()
	closeErr := file.Close()
	return errors.Join(writeErr, syncErr, closeErr)
}

// artifactRecord hashes a local file and returns its size under the portable
// logical path used by the embedded manifest.
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

// packageDigests converts the bundle's verified package metadata into journal
// evidence keyed by package filename.
func packageDigests(bundle kernel.Bundle) map[string]string {
	digests := make(map[string]string, len(bundle.Packages))
	for _, pkg := range bundle.Packages {
		digests[pkg.Name] = pkg.SHA256
	}
	return digests
}

// md5File computes the legacy digest required by Ubuntu's md5sum.txt format; it
// is not used as a security boundary.
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

// logf emits one consistently prefixed progress line and deliberately ignores
// writer failures so logging cannot invalidate an otherwise sound image build.
func logf(w io.Writer, format string, args ...any) {
	_, _ = fmt.Fprintf(w, "linux-armer: "+format+"\n", args...)
}
