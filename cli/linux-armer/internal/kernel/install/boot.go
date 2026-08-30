package install

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const (
	// maximumModuleEntries bounds recursive inspection of an installed module tree.
	maximumModuleEntries = 500000
	// maximumGRUBBytes bounds GRUB configuration parsing.
	maximumGRUBBytes int64 = 16 << 20
)

// verifyFallback proves that the running fallback has complete boot artefacts.
func verifyFallback(ctx context.Context, root, abi string) (BootEvidence, error) {
	evidence, err := verifyBootFiles(ctx, root, abi)
	if err != nil {
		return BootEvidence{}, fmt.Errorf("fallback ABI %s: %w", abi, err)
	}
	grub, err := rootPath(root, "boot/grub/grub.cfg")
	if err != nil {
		return BootEvidence{}, err
	}
	if err := validateTargetRoute(root, grub, false); err != nil {
		return BootEvidence{}, err
	}
	entries, err := countGRUBEntries(ctx, grub, abi, true, false)
	if err != nil {
		return BootEvidence{}, err
	}
	if entries != 1 {
		return BootEvidence{}, fmt.Errorf("fallback ABI %s requires exactly one ABI-labelled non-recovery GRUB entry; found %d", abi, entries)
	}
	evidence.GRUBEntryCount = entries
	return evidence, nil
}

// verifyInstalled proves that the target ABI has complete boot and DTB artefacts.
func verifyInstalled(ctx context.Context, root, abi string, trees []DeviceTree) (BootEvidence, []FileEvidence, error) {
	evidence, err := verifyBootFiles(ctx, root, abi)
	if err != nil {
		return BootEvidence{}, nil, fmt.Errorf("installed ABI %s: %w", abi, err)
	}
	grub, err := rootPath(root, "boot/grub/grub.cfg")
	if err != nil {
		return BootEvidence{}, nil, err
	}
	if err := validateTargetRoute(root, grub, false); err != nil {
		return BootEvidence{}, nil, err
	}
	entries, err := countGRUBEntries(ctx, grub, abi, true, false)
	if err != nil {
		return BootEvidence{}, nil, err
	}
	if entries != 1 {
		return BootEvidence{}, nil, fmt.Errorf("installed ABI %s requires exactly one ABI-labelled non-recovery GRUB entry; found %d", abi, entries)
	}
	evidence.GRUBEntryCount = entries
	deviceTrees := make([]FileEvidence, 0, len(trees))
	for _, tree := range trees {
		if err := validateTargetRoute(root, tree.TargetPath, false); err != nil {
			return BootEvidence{}, nil, err
		}
		verified, err := requireRegularEvidence(ctx, "device-tree", tree.TargetPath)
		if err != nil {
			return BootEvidence{}, nil, err
		}
		deviceTrees = append(deviceTrees, verified)
	}
	return evidence, deviceTrees, nil
}

// verifyBootFiles checks the kernel image, initramfs, module index, and one module.
func verifyBootFiles(ctx context.Context, root, abi string) (BootEvidence, error) {
	kernelImage, err := rootPath(root, "boot/vmlinuz-"+abi)
	if err != nil {
		return BootEvidence{}, err
	}
	initramfs, err := rootPath(root, "boot/initrd.img-"+abi)
	if err != nil {
		return BootEvidence{}, err
	}
	systemMap, err := rootPath(root, "boot/System.map-"+abi)
	if err != nil {
		return BootEvidence{}, err
	}
	kernelConfig, err := rootPath(root, "boot/config-"+abi)
	if err != nil {
		return BootEvidence{}, err
	}
	if err := validateTargetRoute(root, kernelImage, false); err != nil {
		return BootEvidence{}, err
	}
	if err := validateTargetRoute(root, initramfs, false); err != nil {
		return BootEvidence{}, err
	}
	if err := validateTargetRoute(root, systemMap, false); err != nil {
		return BootEvidence{}, err
	}
	if err := validateTargetRoute(root, kernelConfig, false); err != nil {
		return BootEvidence{}, err
	}
	imageEvidence, err := requireRegularEvidence(ctx, "kernel-image", kernelImage)
	if err != nil {
		return BootEvidence{}, err
	}
	initramfsEvidence, err := requireRegularEvidence(ctx, "initramfs", initramfs)
	if err != nil {
		return BootEvidence{}, err
	}
	systemMapEvidence, err := requireRegularEvidence(ctx, "system-map", systemMap)
	if err != nil {
		return BootEvidence{}, err
	}
	kernelConfigEvidence, err := requireRegularEvidence(ctx, "kernel-config", kernelConfig)
	if err != nil {
		return BootEvidence{}, err
	}
	moduleTree, moduleFile, dependencyIndex, err := inspectModuleTree(ctx, root, abi)
	if err != nil {
		return BootEvidence{}, err
	}
	return BootEvidence{
		ABI:                    abi,
		KernelImage:            imageEvidence,
		Initramfs:              initramfsEvidence,
		SystemMap:              systemMapEvidence,
		KernelConfig:           kernelConfigEvidence,
		ModulesDependencyIndex: dependencyIndex,
		ModuleTree:             moduleTree,
		ModuleFile:             moduleFile,
	}, nil
}

// inspectModuleTree requires a canonical usr-merged module tree with modules.dep.
func inspectModuleTree(ctx context.Context, root, abi string) (string, FileEvidence, FileEvidence, error) {
	candidates, err := moduleTreeCandidates(root, abi)
	if err != nil {
		return "", FileEvidence{}, FileEvidence{}, err
	}
	moduleTree := ""
	for _, candidate := range candidates {
		if _, err := os.Lstat(candidate); err == nil {
			moduleTree = candidate
			break
		} else if !errors.Is(err, os.ErrNotExist) {
			return "", FileEvidence{}, FileEvidence{}, fmt.Errorf("inspect module tree %s: %w", candidate, err)
		}
	}
	if moduleTree == "" {
		return "", FileEvidence{}, FileEvidence{}, fmt.Errorf("module tree is missing for ABI %s", abi)
	}
	if err := validateTargetRoute(root, moduleTree, false); err != nil {
		return "", FileEvidence{}, FileEvidence{}, err
	}
	info, err := os.Lstat(moduleTree)
	if err != nil {
		return "", FileEvidence{}, FileEvidence{}, fmt.Errorf("inspect module tree %s: %w", moduleTree, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", FileEvidence{}, FileEvidence{}, fmt.Errorf("module tree must be a non-symlink directory: %s", moduleTree)
	}
	dependencyPath := filepath.Join(moduleTree, "modules.dep")
	dependencyEvidence, err := requireRegularEvidence(ctx, "modules-dependency-index", dependencyPath)
	if err != nil {
		return "", FileEvidence{}, FileEvidence{}, err
	}
	moduleFile := ""
	entries := 0
	err = filepath.WalkDir(moduleTree, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		entries++
		if entries > maximumModuleEntries {
			return fmt.Errorf("module tree exceeds %d entries", maximumModuleEntries)
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		if entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("module tree contains a non-regular entry: %s", path)
		}
		if moduleFile == "" && info.Size() > 0 && isKernelModule(path) {
			moduleFile = path
		}
		return nil
	})
	if err != nil {
		return "", FileEvidence{}, FileEvidence{}, fmt.Errorf("inspect module tree %s: %w", moduleTree, err)
	}
	if moduleFile == "" {
		return "", FileEvidence{}, FileEvidence{}, fmt.Errorf("module tree contains no non-empty kernel module: %s", moduleTree)
	}
	moduleEvidence, err := requireRegularEvidence(ctx, "kernel-module", moduleFile)
	if err != nil {
		return "", FileEvidence{}, FileEvidence{}, err
	}
	return moduleTree, moduleEvidence, dependencyEvidence, nil
}

// isKernelModule recognises the supported plain and compressed module suffixes.
func isKernelModule(path string) bool {
	return strings.HasSuffix(path, ".ko") || strings.HasSuffix(path, ".ko.xz") || strings.HasSuffix(path, ".ko.zst")
}

// verifyTargetAbsent requires a fresh ABI before package-manager mutation.
func verifyTargetAbsent(ctx context.Context, root, abi string) error {
	paths := []string{
		"boot/vmlinuz-" + abi,
		"boot/initrd.img-" + abi,
		"boot/System.map-" + abi,
		"boot/config-" + abi,
		"usr/lib/firmware/" + abi,
		"usr/src/linux-headers-" + abi,
		"usr/src/linux-headers-" + strings.TrimSuffix(abi, "-qcom-x1e"),
	}
	for _, relative := range paths {
		target, err := rootPath(root, relative)
		if err != nil {
			return err
		}
		if err := validateTargetRoute(root, target, true); err != nil {
			return err
		}
		if _, err := os.Lstat(target); err == nil {
			return fmt.Errorf("target ABI already has an installed artefact: %s", target)
		} else if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("inspect target ABI path %s: %w", target, err)
		}
	}
	moduleTrees, err := moduleTreeCandidates(root, abi)
	if err != nil {
		return err
	}
	for _, target := range moduleTrees {
		if err := validateTargetRoute(root, target, true); err != nil {
			return err
		}
		if _, err := os.Lstat(target); err == nil {
			return fmt.Errorf("target ABI already has an installed artefact: %s", target)
		} else if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("inspect target ABI path %s: %w", target, err)
		}
	}
	grub, err := rootPath(root, "boot/grub/grub.cfg")
	if err != nil {
		return err
	}
	if err := validateTargetRoute(root, grub, false); err != nil {
		return err
	}
	entries, err := countGRUBEntries(ctx, grub, abi, false, true)
	if err != nil {
		return err
	}
	if entries != 0 {
		return fmt.Errorf("target ABI %s already has %d GRUB entries", abi, entries)
	}
	return nil
}

// moduleTreeCandidates returns the usr-merged path and any real legacy /lib path.
func moduleTreeCandidates(root, abi string) ([]string, error) {
	usrTree, err := rootPath(root, "usr/lib/modules/"+abi)
	if err != nil {
		return nil, err
	}
	candidates := []string{usrTree}
	legacyBase, err := rootPath(root, "lib")
	if err != nil {
		return nil, err
	}
	info, err := os.Lstat(legacyBase)
	if errors.Is(err, os.ErrNotExist) {
		return candidates, nil
	}
	if err != nil {
		return nil, fmt.Errorf("inspect legacy module root %s: %w", legacyBase, err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return candidates, nil
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("legacy module root is not a directory: %s", legacyBase)
	}
	legacyTree, err := rootPath(root, "lib/modules/"+abi)
	if err != nil {
		return nil, err
	}
	return append(candidates, legacyTree), nil
}

// countGRUBEntries counts matching non-recovery menu entries without executing GRUB.
func countGRUBEntries(ctx context.Context, path, abi string, requireTitle, includeRecovery bool) (int, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return 0, fmt.Errorf("inspect GRUB configuration %s: %w", path, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maximumGRUBBytes {
		return 0, fmt.Errorf("GRUB configuration must be a non-empty regular file no larger than %d bytes: %s", maximumGRUBBytes, path)
	}
	file, opened, err := openUnchangedRegular(path, info)
	if err != nil {
		return 0, fmt.Errorf("open GRUB configuration: %w", err)
	}
	defer file.Close()

	type entryState struct {
		active       bool
		titleMatches bool
		recovery     bool
		kernel       bool
		initramfs    bool
	}
	state := entryState{}
	count := 0
	finish := func() {
		if state.active && (includeRecovery || !state.recovery) && state.kernel && state.initramfs && (!requireTitle || state.titleMatches) {
			count++
		}
	}
	scanner := bufio.NewScanner(io.LimitReader(file, maximumGRUBBytes+1))
	scanner.Buffer(make([]byte, 4096), 1<<20)
	for scanner.Scan() {
		if err := ctx.Err(); err != nil {
			return 0, err
		}
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "menuentry ") {
			finish()
			title, _ := grubMenuTitle(line)
			state = entryState{
				active:       true,
				titleMatches: strings.Contains(title, abi),
				recovery:     strings.Contains(strings.ToLower(title), "recovery"),
			}
			continue
		}
		if !state.active {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		command := fields[0]
		switch command {
		case "linux", "linuxefi":
			state.kernel = state.kernel || pathTokenMatches(fields[1:], "vmlinuz-"+abi)
		case "initrd", "initrdefi":
			state.initramfs = state.initramfs || pathTokenMatches(fields[1:], "initrd.img-"+abi)
		}
	}
	if err := scanner.Err(); err != nil {
		return 0, fmt.Errorf("read GRUB configuration: %w", err)
	}
	finish()
	entry, statErr := os.Lstat(path)
	if statErr != nil || entry.Mode()&os.ModeSymlink != 0 || !os.SameFile(opened, entry) {
		return 0, fmt.Errorf("GRUB configuration changed while it was inspected: %s", path)
	}
	return count, nil
}

// grubMenuTitle extracts the first quoted or unquoted GRUB menu title.
func grubMenuTitle(line string) (string, bool) {
	remainder := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "menuentry"))
	if remainder == "" {
		return "", false
	}
	quote := remainder[0]
	if quote != '\'' && quote != '"' {
		fields := strings.Fields(remainder)
		if len(fields) == 0 {
			return "", false
		}
		return fields[0], true
	}
	escaped := false
	for index := 1; index < len(remainder); index++ {
		character := remainder[index]
		if quote == '"' && character == '\\' && !escaped {
			escaped = true
			continue
		}
		if character == quote && !escaped {
			return remainder[1:index], true
		}
		escaped = false
	}
	return "", false
}

// pathTokenMatches reports whether any GRUB path token ends in the exact artefact.
func pathTokenMatches(tokens []string, basename string) bool {
	for _, token := range tokens {
		token = strings.Trim(token, "'\"")
		if token == basename || strings.HasSuffix(token, "/"+basename) {
			return true
		}
	}
	return false
}

// fallbackUnchanged compares the safety-critical fallback identities before and after.
func fallbackUnchanged(before, after BootEvidence) error {
	if before.ABI != after.ABI || before.KernelImage.SHA256 != after.KernelImage.SHA256 ||
		before.Initramfs.SHA256 != after.Initramfs.SHA256 ||
		before.SystemMap.SHA256 != after.SystemMap.SHA256 ||
		before.KernelConfig.SHA256 != after.KernelConfig.SHA256 ||
		before.ModulesDependencyIndex.SHA256 != after.ModulesDependencyIndex.SHA256 ||
		before.ModuleFile.SHA256 != after.ModuleFile.SHA256 ||
		after.GRUBEntryCount != 1 {
		return fmt.Errorf("fallback ABI %s changed or became unbootable during installation", before.ABI)
	}
	return nil
}
