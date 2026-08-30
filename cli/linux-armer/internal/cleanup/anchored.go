package cleanup

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// DirectoryIdentity binds a reviewed plan or receipt to one exact filesystem
// directory rather than merely to a replaceable pathname.
type DirectoryIdentity struct {
	// Device is the Unix device number containing the directory.
	Device uint64 `json:"device"`
	// Inode is the Unix inode number of the directory.
	Inode uint64 `json:"inode"`
}

// valid reports whether an identity contains the non-zero inode required for
// safe plan and receipt binding.
func (identity DirectoryIdentity) valid() bool {
	return identity.Inode != 0
}

// anchoredRoots owns descriptor-relative roots for the selected target and,
// when requested, the exact explicit user home opened beneath that target.
type anchoredRoots struct {
	// target is the stable target-root descriptor used for system rules and backups.
	target *os.Root
	// user is the stable explicit-home descriptor used only for per-user rules.
	user *os.Root
	// rootPath is the canonical public target-root pathname.
	rootPath string
	// userHome is the canonical target-visible user-home pathname.
	userHome string
	// userBase is the host pathname used only for public reports and receipts.
	userBase string
	// rootIdentity identifies the exact opened target root.
	rootIdentity DirectoryIdentity
	// userIdentity identifies the exact opened user home when selected.
	userIdentity *DirectoryIdentity
}

// anchoredLocation couples one descriptor-relative operation root with the
// public absolute base path used in plans and receipts.
type anchoredLocation struct {
	// root performs traversal-resistant filesystem operations.
	root *os.Root
	// publicBase is the corresponding absolute report-path prefix.
	publicBase string
}

// anchoredRecoverySource identifies one verified recovery object relative to
// the stable root that contains it.
type anchoredRecoverySource struct {
	// root confines every recovery read to its opened directory tree.
	root *os.Root
	// name is the descriptor-relative source name.
	name string
	// publicPath is the receipt path used only in operator-facing errors.
	publicPath string
}

// anchoredParent holds the stable descriptor for one entry's immediate parent
// and records whether the caller must close that derived descriptor.
type anchoredParent struct {
	// location couples the stable parent root with its public display path.
	location anchoredLocation
	// leaf is the one-component entry name below location.
	leaf string
	// handle is the stable immediate-parent descriptor used by *at operations.
	handle *os.File
	// owned reports whether close must release a derived parent root.
	owned bool
}

// close releases a derived parent root while leaving a borrowed top-level root
// under its original owner.
func (parent anchoredParent) close() error {
	var handleErr error
	if parent.handle != nil {
		handleErr = parent.handle.Close()
	}
	if !parent.owned || parent.location.root == nil {
		return handleErr
	}
	return errors.Join(handleErr, parent.location.root.Close())
}

// openAnchoredParent opens every directory component preceding an entry and
// returns its single leaf name relative to that stable immediate parent.
func openAnchoredParent(base anchoredLocation, name string) (anchoredParent, error) {
	clean := filepath.Clean(name)
	if clean == "." || filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return anchoredParent{}, fmt.Errorf("unsafe anchored entry %q", name)
	}
	leaf := filepath.Base(clean)
	directory := filepath.Dir(clean)
	if directory == "." {
		handle, err := base.root.Open(".")
		if err != nil {
			return anchoredParent{}, err
		}
		return anchoredParent{location: base, leaf: leaf, handle: handle}, nil
	}
	root, _, err := openStableNestedRoot(base.root, directory)
	if err != nil {
		return anchoredParent{}, err
	}
	handle, err := root.Open(".")
	if err != nil {
		_ = root.Close()
		return anchoredParent{}, err
	}
	return anchoredParent{
		location: anchoredLocation{root: root, publicBase: filepath.Join(base.publicBase, directory)},
		leaf:     leaf, handle: handle, owned: true,
	}, nil
}

// restoreOperations isolates the two no-overwrite publication operations so
// hostile tests can swap visible ancestors after roots have been opened.
type restoreOperations struct {
	// link publishes a prepared regular file without replacing an existing name.
	link func(*os.File, string, *os.File, string) error
	// symlink publishes an exact symbolic-link target without replacing a name.
	symlink func(*os.Root, string, string) error
}

// openAnchoredRoots opens and identity-checks the exact target root and
// optional user home before any scan or mutation can proceed.
func openAnchoredRoots(root, userHome string) (*anchoredRoots, error) {
	resolvedRoot, err := ResolveRoot(root)
	if err != nil {
		return nil, err
	}
	resolvedUserHome, err := ResolveUserHome(resolvedRoot, userHome)
	if err != nil {
		return nil, err
	}
	target, rootIdentity, err := openStablePathRoot(resolvedRoot)
	if err != nil {
		return nil, fmt.Errorf("open anchored cleanup root: %w", err)
	}
	roots := &anchoredRoots{target: target, rootPath: resolvedRoot, userHome: resolvedUserHome, rootIdentity: rootIdentity}
	if resolvedUserHome == "" {
		return roots, nil
	}
	userRelative := strings.TrimPrefix(filepath.FromSlash(resolvedUserHome), string(filepath.Separator))
	user, userIdentity, err := openStableNestedRoot(target, userRelative)
	if err != nil {
		_ = target.Close()
		return nil, fmt.Errorf("open anchored cleanup user home %q: %w", resolvedUserHome, err)
	}
	roots.user = user
	roots.userBase = filepath.Join(resolvedRoot, userRelative)
	roots.userIdentity = &userIdentity
	return roots, nil
}

// openStablePathRoot detects replacement of a pathname before, during, or
// immediately after os.OpenRoot obtains its stable directory descriptor.
func openStablePathRoot(path string) (*os.Root, DirectoryIdentity, error) {
	resolvedBefore, err := filepath.EvalSymlinks(path)
	if err != nil {
		return nil, DirectoryIdentity{}, err
	}
	if resolvedBefore != path {
		return nil, DirectoryIdentity{}, errors.New("cleanup root route is not canonical")
	}
	before, err := os.Lstat(path)
	if err != nil {
		return nil, DirectoryIdentity{}, err
	}
	if before.Mode()&os.ModeSymlink != 0 || !before.IsDir() {
		return nil, DirectoryIdentity{}, errors.New("cleanup root is not a real directory")
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		return nil, DirectoryIdentity{}, err
	}
	opened, openedErr := root.Stat(".")
	after, afterErr := os.Lstat(path)
	resolvedAfter, resolvedErr := filepath.EvalSymlinks(path)
	if openedErr != nil || afterErr != nil || after.Mode()&os.ModeSymlink != 0 || !after.IsDir() ||
		resolvedErr != nil || resolvedAfter != path || !os.SameFile(before, opened) || !os.SameFile(opened, after) {
		_ = root.Close()
		return nil, DirectoryIdentity{}, errors.New("cleanup root changed while it was being opened")
	}
	identity, err := directoryIdentity(opened)
	if err != nil {
		_ = root.Close()
		return nil, DirectoryIdentity{}, err
	}
	return root, identity, nil
}

// openStableNestedRoot opens every component of a real descendant through the
// preceding stable descriptor, rejecting intermediate links and replacement
// races before advancing to the next component.
func openStableNestedRoot(parent *os.Root, relative string) (*os.Root, DirectoryIdentity, error) {
	clean := filepath.Clean(relative)
	if clean == "." || filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return nil, DirectoryIdentity{}, fmt.Errorf("unsafe nested cleanup root %q", relative)
	}
	current := parent
	owned := false
	var identity DirectoryIdentity
	for _, component := range strings.Split(clean, string(filepath.Separator)) {
		if component == "" || component == "." || component == ".." {
			if owned {
				_ = current.Close()
			}
			return nil, DirectoryIdentity{}, fmt.Errorf("unsafe nested cleanup root %q", relative)
		}
		next, nextIdentity, err := openStableChildRoot(current, component)
		if err != nil {
			if owned {
				_ = current.Close()
			}
			return nil, DirectoryIdentity{}, err
		}
		if owned {
			if err := current.Close(); err != nil {
				_ = next.Close()
				return nil, DirectoryIdentity{}, err
			}
		}
		current = next
		identity = nextIdentity
		owned = true
	}
	return current, identity, nil
}

// openStableChildRoot opens one real child directory and compares its identity
// before, through, and after acquisition of the child descriptor.
func openStableChildRoot(parent *os.Root, component string) (*os.Root, DirectoryIdentity, error) {
	if component == "" || component == "." || component == ".." || filepath.Base(component) != component {
		return nil, DirectoryIdentity{}, fmt.Errorf("unsafe nested cleanup component %q", component)
	}
	before, err := parent.Lstat(component)
	if err != nil {
		return nil, DirectoryIdentity{}, err
	}
	if before.Mode()&os.ModeSymlink != 0 || !before.IsDir() {
		return nil, DirectoryIdentity{}, errors.New("nested cleanup root is not a real directory")
	}
	root, err := parent.OpenRoot(component)
	if err != nil {
		return nil, DirectoryIdentity{}, err
	}
	opened, openedErr := root.Stat(".")
	after, afterErr := parent.Lstat(component)
	if openedErr != nil || afterErr != nil || after.Mode()&os.ModeSymlink != 0 || !after.IsDir() ||
		!os.SameFile(before, opened) || !os.SameFile(opened, after) {
		_ = root.Close()
		return nil, DirectoryIdentity{}, errors.New("nested cleanup root changed while it was being opened")
	}
	identity, err := directoryIdentity(opened)
	if err != nil {
		_ = root.Close()
		return nil, DirectoryIdentity{}, err
	}
	return root, identity, nil
}

// directoryIdentity extracts the stable Unix device and inode pair shared by
// plans, receipts, and opened-root revalidation.
func directoryIdentity(info os.FileInfo) (DirectoryIdentity, error) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return DirectoryIdentity{}, errors.New("filesystem metadata has no Unix directory identity")
	}
	identity := DirectoryIdentity{Device: uint64(stat.Dev), Inode: uint64(stat.Ino)}
	if !identity.valid() {
		return DirectoryIdentity{}, errors.New("filesystem directory identity is invalid")
	}
	return identity, nil
}

// locationForRule selects the descriptor root compiled for one rule scope.
func (roots *anchoredRoots) locationForRule(rule Rule) (anchoredLocation, bool, error) {
	if roots == nil || roots.target == nil {
		return anchoredLocation{}, false, errors.New("cleanup roots are not open")
	}
	switch rule.scope {
	case ruleScopeSystem:
		return anchoredLocation{root: roots.target, publicBase: roots.rootPath}, true, nil
	case ruleScopeUser:
		if roots.user == nil {
			return anchoredLocation{}, false, nil
		}
		return anchoredLocation{root: roots.user, publicBase: roots.userBase}, true, nil
	default:
		return anchoredLocation{}, false, fmt.Errorf("cleanup rule %s has an unknown scope", rule.ID)
	}
}

// requireIdentities binds opened descriptors to the exact reviewed plan or
// receipt directory identities before any mutation.
func (roots *anchoredRoots) requireIdentities(rootIdentity DirectoryIdentity, userIdentity *DirectoryIdentity) error {
	if roots.rootIdentity != rootIdentity || !rootIdentity.valid() {
		return errors.New("cleanup target root identity differs from the reviewed state")
	}
	if roots.user == nil {
		if userIdentity != nil {
			return errors.New("cleanup reviewed state unexpectedly includes a user-home identity")
		}
		return nil
	}
	if userIdentity == nil || roots.userIdentity == nil || *roots.userIdentity != *userIdentity || !userIdentity.valid() {
		return errors.New("cleanup user-home identity differs from the reviewed state")
	}
	return nil
}

// close releases both stable roots and joins any close failures.
func (roots *anchoredRoots) close() error {
	if roots == nil {
		return nil
	}
	var userErr error
	if roots.user != nil {
		userErr = roots.user.Close()
	}
	var targetErr error
	if roots.target != nil {
		targetErr = roots.target.Close()
	}
	return errors.Join(userErr, targetErr)
}

// ensureAnchoredBackupParent creates and validates the standard backup
// hierarchy entirely through the stable target-root descriptor.
func ensureAnchoredBackupParent(root *os.Root, publicRoot string) error {
	directories := []struct {
		component string
		mode      os.FileMode
	}{
		{component: "var", mode: 0o755},
		{component: "lib", mode: 0o755},
		{component: "linux-armer", mode: 0o700},
		{component: "backups", mode: 0o700},
	}
	current := root
	owned := false
	publicPath := publicRoot
	for _, directory := range directories {
		publicPath = filepath.Join(publicPath, directory.component)
		if err := ensureAnchoredDirectory(current, directory.component, publicPath, directory.mode); err != nil {
			if owned {
				_ = current.Close()
			}
			return err
		}
		next, _, err := openStableChildRoot(current, directory.component)
		if err != nil {
			if owned {
				_ = current.Close()
			}
			return err
		}
		if owned {
			if err := current.Close(); err != nil {
				_ = next.Close()
				return err
			}
		}
		current = next
		owned = true
	}
	if owned {
		return current.Close()
	}
	return nil
}

// ensureAnchoredDirectory creates one descriptor-relative directory, applies
// its exact mode through an opened file descriptor, and validates ownership.
func ensureAnchoredDirectory(root *os.Root, relative, publicPath string, mode os.FileMode) error {
	info, err := root.Lstat(relative)
	if err == nil {
		if mode == 0o700 {
			return validatePrivateDirectoryInfo(publicPath, info)
		}
		return validateTrustedDirectoryInfo(publicPath, info)
	}
	if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := root.Mkdir(relative, mode); err != nil {
		return err
	}
	directory, err := root.Open(relative)
	if err != nil {
		return err
	}
	chmodErr := directory.Chmod(mode)
	syncErr := directory.Sync()
	closeErr := directory.Close()
	if err := errors.Join(chmodErr, syncErr, closeErr); err != nil {
		return err
	}
	info, err = root.Lstat(relative)
	if err != nil {
		return err
	}
	if mode == 0o700 {
		if err := validatePrivateDirectoryInfo(publicPath, info); err != nil {
			return err
		}
	} else if err := validateTrustedDirectoryInfo(publicPath, info); err != nil {
		return err
	}
	return syncAnchoredDirectory(root, filepath.Dir(relative))
}

// ensureAnchoredPrivateDirectories creates every missing backup subdirectory
// with mode 0700 through an already private backup root.
func ensureAnchoredPrivateDirectories(root *os.Root, relative string) error {
	clean := filepath.Clean(relative)
	if clean == "." {
		return nil
	}
	current := ""
	for _, part := range strings.Split(clean, string(filepath.Separator)) {
		if part == "" || part == "." || part == ".." {
			return fmt.Errorf("unsafe private backup directory %q", relative)
		}
		current = filepath.Join(current, part)
		if err := ensureAnchoredDirectory(root, current, filepath.Join(root.Name(), current), 0o700); err != nil {
			return err
		}
	}
	return nil
}

// syncAnchoredDirectory persists directory entries through the stable root.
func syncAnchoredDirectory(root *os.Root, relative string) error {
	if relative == "" {
		relative = "."
	}
	directory, err := root.Open(relative)
	if err != nil {
		return err
	}
	syncErr := directory.Sync()
	closeErr := directory.Close()
	return errors.Join(syncErr, closeErr)
}

// writeAnchoredJSON creates and persists one private JSON file through a
// stable root without permitting pathname traversal outside it.
func writeAnchoredJSON(root *os.Root, name string, value any) error {
	file, err := root.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return err
	}
	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	encodeErr := encoder.Encode(value)
	syncErr := file.Sync()
	closeErr := file.Close()
	return errors.Join(encodeErr, syncErr, closeErr)
}

// copyAnchoredEntry copies a regular file or symbolic link between stable
// roots while preserving mode and numeric ownership through descriptors.
func copyAnchoredEntry(sourceRoot *os.Root, sourceName string, destinationRoot *os.Root, destinationName string) error {
	before, err := sourceRoot.Lstat(sourceName)
	if err != nil {
		return err
	}
	if before.Mode()&os.ModeSymlink != 0 {
		target, sourceInfo, err := readAnchoredSymlink(sourceRoot, sourceName)
		if err != nil {
			return err
		}
		uid, gid, err := fileOwnership(sourceInfo)
		if err != nil {
			return err
		}
		if err := destinationRoot.Symlink(target, destinationName); err != nil {
			return err
		}
		if err := ensureAnchoredSymlinkOwnership(destinationRoot, destinationName, uid, gid); err != nil {
			return errors.Join(err, removeAnchoredDestination(destinationRoot, destinationName))
		}
		createdTarget, _, err := readAnchoredSymlink(destinationRoot, destinationName)
		if err != nil || createdTarget != target {
			return errors.Join(err, errors.New("copied symbolic link changed during creation"), removeAnchoredDestination(destinationRoot, destinationName))
		}
		return nil
	}
	if !before.Mode().IsRegular() || before.Size() < 0 || before.Size() > maximumLegacyFileBytes {
		return errLegacyFileTooLarge
	}
	source, err := sourceRoot.Open(sourceName)
	if err != nil {
		return err
	}
	defer source.Close()
	opened, err := source.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(before, opened) || opened.Size() != before.Size() {
		return errors.Join(err, errors.New("anchored copy source changed while it was opened"))
	}
	afterOpen, err := sourceRoot.Lstat(sourceName)
	if err != nil || !os.SameFile(before, afterOpen) {
		return errors.Join(err, errors.New("anchored copy source changed while it was opened"))
	}
	uid, gid, err := fileOwnership(opened)
	if err != nil {
		return err
	}
	destination, err := destinationRoot.OpenFile(destinationName, os.O_CREATE|os.O_EXCL|os.O_WRONLY, opened.Mode().Perm())
	if err != nil {
		return err
	}
	copied, copyErr := io.Copy(destination, io.LimitReader(source, maximumLegacyFileBytes+1))
	if copyErr == nil && copied != opened.Size() {
		copyErr = fmt.Errorf("copied %d bytes, want %d", copied, opened.Size())
	}
	ownershipErr := ensureOpenFileOwnership(destination, uid, gid)
	chmodErr := destination.Chmod(opened.Mode().Perm())
	syncErr := destination.Sync()
	closeErr := destination.Close()
	finalSource, finalSourceErr := source.Stat()
	afterCopy, afterCopyErr := sourceRoot.Lstat(sourceName)
	changeErr := error(nil)
	if finalSourceErr != nil || afterCopyErr != nil || !os.SameFile(before, finalSource) || !os.SameFile(before, afterCopy) ||
		finalSource.Size() != opened.Size() || finalSource.Mode() != opened.Mode() ||
		finalSource.ModTime() != opened.ModTime() || afterCopy.ModTime() != opened.ModTime() {
		changeErr = errors.New("anchored copy source changed while it was copied")
	}
	result := errors.Join(copyErr, ownershipErr, chmodErr, syncErr, closeErr, finalSourceErr, afterCopyErr, changeErr)
	if result != nil {
		return errors.Join(result, removeAnchoredDestination(destinationRoot, destinationName))
	}
	return nil
}

// unsupportedAnchoredRecoveryMetadata reports metadata that the recovery
// format cannot reproduce exactly, including hard links, special mode bits,
// extended attributes, capabilities, ACLs, and security labels.
func unsupportedAnchoredRecoveryMetadata(root *os.Root, name string, inspected os.FileInfo, expectedLinks uint64) (string, error) {
	if inspected.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
		return "special permission bits cannot be reproduced by automatic clean-up", nil
	}
	stat, ok := inspected.Sys().(*syscall.Stat_t)
	if !ok {
		return "", errors.New("filesystem metadata has no Unix link count")
	}
	if uint64(stat.Nlink) != expectedLinks {
		return "hard-linked files cannot be reproduced exactly by automatic clean-up", nil
	}
	file, err := root.Open(name)
	if err != nil {
		return "", err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(inspected, opened) {
		return "", errors.Join(err, errors.New("recovery metadata target changed while it was opened"))
	}
	attributeNames, err := anchoredExtendedAttributeNames(file)
	if err != nil {
		return "", err
	}
	for _, attributeName := range attributeNames {
		if attributeName == "com.apple.provenance" {
			continue
		}
		return "extended attributes, capabilities, ACLs, or security labels cannot be reproduced by automatic clean-up", nil
	}
	after, err := root.Lstat(name)
	if err != nil || !os.SameFile(inspected, after) {
		return "", errors.Join(err, errors.New("recovery metadata target changed during inspection"))
	}
	return "", nil
}

// anchoredExtendedAttributeNames lists descriptor metadata without reading
// attribute values and treats filesystems without xattr support as empty.
func anchoredExtendedAttributeNames(file *os.File) ([]string, error) {
	size, err := unix.Flistxattr(int(file.Fd()), nil)
	if errors.Is(err, unix.ENOTSUP) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if size == 0 {
		return nil, nil
	}
	buffer := make([]byte, size)
	written, err := unix.Flistxattr(int(file.Fd()), buffer)
	if err != nil {
		return nil, err
	}
	if written < 0 || written > len(buffer) {
		return nil, errors.New("extended-attribute list has an invalid length")
	}
	names := make([]string, 0)
	for _, encoded := range strings.Split(string(buffer[:written]), "\x00") {
		if encoded != "" {
			names = append(names, encoded)
		}
	}
	return names, nil
}

// removeAnchoredDestination removes a failed copy and durably records that
// recovery cleanup before returning the joined failure to its caller.
func removeAnchoredDestination(root *os.Root, name string) error {
	removeErr := root.Remove(name)
	if errors.Is(removeErr, os.ErrNotExist) {
		removeErr = nil
	}
	return errors.Join(removeErr, syncAnchoredDirectory(root, filepath.Dir(name)))
}

// ensureOpenFileOwnership changes regular-file ownership only when the opened
// descriptor does not already carry the requested numeric owner and group.
func ensureOpenFileOwnership(file *os.File, uid, gid uint32) error {
	info, err := file.Stat()
	if err != nil {
		return err
	}
	currentUID, currentGID, err := fileOwnership(info)
	if err != nil {
		return err
	}
	if currentUID == uid && currentGID == gid {
		return nil
	}
	return file.Chown(int(uid), int(gid))
}

// ensureAnchoredSymlinkOwnership changes link ownership without following the
// link and verifies the requested numeric owner through the anchored root.
func ensureAnchoredSymlinkOwnership(root *os.Root, name string, uid, gid uint32) error {
	info, err := root.Lstat(name)
	if err != nil {
		return err
	}
	currentUID, currentGID, err := fileOwnership(info)
	if err != nil {
		return err
	}
	if currentUID != uid || currentGID != gid {
		if err := root.Lchown(name, int(uid), int(gid)); err != nil {
			return err
		}
	}
	verified, err := root.Lstat(name)
	if err != nil || verified.Mode()&os.ModeSymlink == 0 {
		return errors.Join(err, errors.New("anchored symbolic link changed during ownership restoration"))
	}
	verifiedUID, verifiedGID, err := fileOwnership(verified)
	if err != nil {
		return err
	}
	if verifiedUID != uid || verifiedGID != gid {
		return errors.New("anchored symbolic-link ownership differs after restoration")
	}
	return nil
}

// createAnchoredPrivateIntegrityKey creates the private MAC-integrity key
// through the anchored backup root and verifies its descriptor metadata.
func createAnchoredPrivateIntegrityKey(root *os.Root) ([]byte, error) {
	key := make([]byte, privateIntegrityKeyBytes)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	file, err := root.OpenFile(privateIntegrityKeyName, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	writeCount, writeErr := file.Write(key)
	chmodErr := file.Chmod(0o600)
	info, statErr := file.Stat()
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(writeErr, chmodErr, statErr, syncErr, closeErr); err != nil {
		return nil, err
	}
	if writeCount != len(key) {
		return nil, io.ErrShortWrite
	}
	uid, _, ownerErr := fileOwnership(info)
	if ownerErr != nil || uid != uint32(os.Geteuid()) || info.Mode().Perm() != 0o600 || !info.Mode().IsRegular() {
		return nil, errors.New("private cleanup integrity key has unsafe metadata")
	}
	if err := syncAnchoredDirectory(root, "."); err != nil {
		return nil, err
	}
	return key, nil
}

// readAnchoredSymlink reads one link without following it and rejects a leaf
// replacement that occurs around the descriptor-relative read.
func readAnchoredSymlink(root *os.Root, name string) (string, os.FileInfo, error) {
	before, err := root.Lstat(name)
	if err != nil {
		return "", nil, err
	}
	if before.Mode()&os.ModeSymlink == 0 {
		return "", nil, errors.New("anchored entry is not a symbolic link")
	}
	target, err := root.Readlink(name)
	if err != nil {
		return "", nil, err
	}
	after, err := root.Lstat(name)
	if err != nil || after.Mode()&os.ModeSymlink == 0 || !os.SameFile(before, after) {
		return "", nil, errors.Join(err, errors.New("anchored symbolic link changed while it was read"))
	}
	return target, after, nil
}

// hmacRootFile authenticates one exact bounded regular file through its
// stable root without exposing private low-entropy contents.
func hmacRootFile(root *os.Root, name string, key []byte, size int64) (string, error) {
	if len(key) != privateIntegrityKeyBytes || size < 0 || size > maximumLegacyFileBytes {
		return "", errors.New("private cleanup integrity input is invalid")
	}
	data, err := readBoundedRootRegular(root, name, maximumLegacyFileBytes)
	if err != nil {
		return "", err
	}
	if int64(len(data)) != size {
		return "", fmt.Errorf("private cleanup file size is %d, want %d", len(data), size)
	}
	return hmacPrivateBytes(data, key)
}

// hmacPrivateBytes authenticates already validated private bytes with the
// transaction key retained only inside the private backup.
func hmacPrivateBytes(data, key []byte) (string, error) {
	if len(key) != privateIntegrityKeyBytes {
		return "", errors.New("private cleanup integrity key has an invalid length")
	}
	mac := hmac.New(sha256.New, key)
	if _, err := mac.Write(data); err != nil {
		return "", err
	}
	return hex.EncodeToString(mac.Sum(nil)), nil
}

// validateAnchoredRuleContent rereads one regular target through its stable
// parent and applies the closed compiled signature before private bytes can be
// authenticated for removal.
func validateAnchoredRuleContent(root *os.Root, name string, rule Rule, finding Finding) ([]byte, error) {
	maximum := rule.maximumSize
	if maximum <= 0 {
		maximum = maximumLegacyFileBytes
	}
	data, err := readBoundedRootRegular(root, name, maximum)
	if err != nil {
		return nil, err
	}
	if int64(len(data)) != finding.Size {
		return nil, fmt.Errorf("recognised content size is %d, want %d", len(data), finding.Size)
	}
	if len(rule.prefix) != 0 && !strings.HasPrefix(string(data), string(rule.prefix)) {
		return nil, errors.New("recognised content signature changed")
	}
	for _, marker := range rule.Markers {
		if !strings.Contains(string(data), marker) {
			return nil, errors.New("recognised content marker changed")
		}
	}
	if rule.validateContent != nil && !rule.validateContent(data) {
		return nil, errors.New("recognised content format changed")
	}
	return data, nil
}

// verifyAnchoredFinding proves that one descriptor-relative entry still
// matches the reviewed finding and returns its exact current inode metadata.
func verifyAnchoredFinding(root *os.Root, name string, finding Finding, change ReceiptItem, integrityKey []byte) (os.FileInfo, error) {
	info, err := root.Lstat(name)
	if err != nil {
		return nil, err
	}
	uid, gid, err := fileOwnership(info)
	if err != nil {
		return nil, err
	}
	if uint32(info.Mode().Perm()) != finding.Mode || uid != finding.UID || gid != finding.GID {
		return nil, errors.New("object mode or ownership changed")
	}
	switch finding.Kind {
	case "file":
		if !info.Mode().IsRegular() || info.Size() != finding.Size {
			return nil, errors.New("object kind or size changed")
		}
		unsupported, err := unsupportedAnchoredRecoveryMetadata(root, name, info, 1)
		if err != nil {
			return nil, err
		}
		if unsupported != "" {
			return nil, errors.New(unsupported)
		}
		if change.HMACSHA256 != "" {
			got, err := hmacRootFile(root, name, integrityKey, finding.Size)
			if err != nil {
				return nil, err
			}
			if !hmac.Equal([]byte(got), []byte(change.HMACSHA256)) {
				return nil, errors.New("private content integrity changed")
			}
		} else {
			data, err := readBoundedRootRegular(root, name, maximumLegacyFileBytes)
			if err != nil {
				return nil, err
			}
			digest := sha256.Sum256(data)
			if got := hex.EncodeToString(digest[:]); got != finding.SHA256 {
				return nil, fmt.Errorf("SHA-256 is %s, want %s", got, finding.SHA256)
			}
		}
	case "symlink":
		target, linkInfo, err := readAnchoredSymlink(root, name)
		if err != nil {
			return nil, err
		}
		if target != finding.SymlinkTarget {
			return nil, fmt.Errorf("symbolic-link target is %q, want %q", target, finding.SymlinkTarget)
		}
		info = linkInfo
	default:
		return nil, fmt.Errorf("unsupported reviewed object kind %q", finding.Kind)
	}
	final, err := root.Lstat(name)
	if err != nil || !os.SameFile(info, final) {
		return nil, errors.Join(err, errors.New("anchored finding changed during verification"))
	}
	return final, nil
}

// verifyAnchoredReceiptEntry compares one rooted object with the exact
// integrity and metadata fields retained in a recovery receipt.
func verifyAnchoredReceiptEntry(root *os.Root, name string, change ReceiptItem, integrityKey []byte) error {
	return verifyAnchoredReceiptEntryLinks(root, name, change, integrityKey, 1)
}

// verifyAnchoredReceiptEntryLinks validates one recovery entry while allowing
// the exact temporary hard-link count used during atomic publication.
func verifyAnchoredReceiptEntryLinks(root *os.Root, name string, change ReceiptItem, integrityKey []byte, expectedLinks uint64) error {
	info, err := root.Lstat(name)
	if err != nil {
		return err
	}
	uid, gid, err := fileOwnership(info)
	if err != nil {
		return err
	}
	if uint32(info.Mode().Perm()) != change.Mode || uid != change.UID || gid != change.GID {
		return errors.New("mode or ownership differs from the recovery receipt")
	}
	switch change.Kind {
	case "file":
		if !info.Mode().IsRegular() || info.Size() != change.Size {
			return errors.New("object kind or size differs from the recovery receipt")
		}
		unsupported, err := unsupportedAnchoredRecoveryMetadata(root, name, info, expectedLinks)
		if err != nil {
			return err
		}
		if unsupported != "" {
			return errors.New(unsupported)
		}
		if change.HMACSHA256 != "" {
			got, err := hmacRootFile(root, name, integrityKey, change.Size)
			if err != nil {
				return err
			}
			if !hmac.Equal([]byte(got), []byte(change.HMACSHA256)) {
				return errors.New("private content integrity does not match the recovery receipt")
			}
		} else {
			data, err := readBoundedRootRegular(root, name, maximumLegacyFileBytes)
			if err != nil {
				return err
			}
			digest := sha256.Sum256(data)
			if got := hex.EncodeToString(digest[:]); got != change.SHA256 {
				return fmt.Errorf("SHA-256 is %s, want %s", got, change.SHA256)
			}
		}
	case "symlink":
		target, _, err := readAnchoredSymlink(root, name)
		if err != nil {
			return err
		}
		if target != change.SymlinkTarget {
			return fmt.Errorf("symbolic-link target is %q, want %q", target, change.SymlinkTarget)
		}
	default:
		return fmt.Errorf("unsupported recovery kind %q", change.Kind)
	}
	return nil
}

// removeAnchoredEmptyDirectories removes newly prepared quarantine workspaces
// through their stable roots after a pre-mutation failure.
func removeAnchoredEmptyDirectories(paths []anchoredQuarantine) {
	for index := len(paths) - 1; index >= 0; index-- {
		_ = paths[index].root.Remove(paths[index].name)
		_ = syncAnchoredDirectory(paths[index].root, filepath.Dir(paths[index].name))
	}
}

// openAnchoredBackupRoot opens and validates every component of the fixed
// recovery hierarchy, retaining a stable descriptor for the transaction.
func openAnchoredBackupRoot(target *os.Root, publicRoot, backupRelative string) (*os.Root, error) {
	clean := filepath.Clean(backupRelative)
	parts := strings.Split(clean, string(filepath.Separator))
	want := []string{"var", "lib", "linux-armer", "backups"}
	if len(parts) != len(want)+1 || parts[len(parts)-1] == "" || parts[len(parts)-1] == "." || parts[len(parts)-1] == ".." {
		return nil, fmt.Errorf("cleanup backup has an unsafe transaction path: %s", backupRelative)
	}
	for index := range want {
		if parts[index] != want[index] {
			return nil, fmt.Errorf("cleanup backup is outside the standard hierarchy: %s", backupRelative)
		}
	}
	return openValidatedBackupComponents(target, publicRoot, parts)
}

// openAnchoredBackupParentRoot opens the fixed private backups directory one
// validated component at a time for safe transaction creation.
func openAnchoredBackupParentRoot(target *os.Root, publicRoot string) (*os.Root, error) {
	return openValidatedBackupComponents(target, publicRoot, []string{"var", "lib", "linux-armer", "backups"})
}

// openValidatedBackupComponents advances through already existing recovery
// hierarchy components while holding and validating each stable descriptor.
func openValidatedBackupComponents(target *os.Root, publicRoot string, parts []string) (*os.Root, error) {
	current := target
	owned := false
	for index, component := range parts {
		next, _, err := openStableChildRoot(current, component)
		if err != nil {
			if owned {
				_ = current.Close()
			}
			return nil, fmt.Errorf("open cleanup backup hierarchy component %s: %w", component, err)
		}
		info, statErr := next.Stat(".")
		publicPath := filepath.Join(publicRoot, filepath.Join(parts[:index+1]...))
		validationErr := error(nil)
		if statErr == nil {
			if index >= 2 {
				validationErr = validatePrivateDirectoryInfo(publicPath, info)
			} else {
				validationErr = validateTrustedDirectoryInfo(publicPath, info)
			}
		}
		if err := errors.Join(statErr, validationErr); err != nil {
			_ = next.Close()
			if owned {
				_ = current.Close()
			}
			return nil, err
		}
		if owned {
			if err := current.Close(); err != nil {
				_ = next.Close()
				return nil, err
			}
		}
		current = next
		owned = true
	}
	return current, nil
}

// readAnchoredPrivateIntegrityKey reads the fixed private key only when a
// receipt contains private entries and validates its exact rooted metadata.
func readAnchoredPrivateIntegrityKey(root *os.Root, receipt Receipt) ([]byte, error) {
	required := false
	for _, change := range receipt.Changes {
		if change.HMACSHA256 != "" {
			required = true
			break
		}
	}
	if !required {
		return nil, nil
	}
	info, err := root.Lstat(privateIntegrityKeyName)
	if err != nil {
		return nil, fmt.Errorf("inspect private cleanup integrity key: %w", err)
	}
	uid, _, ownerErr := fileOwnership(info)
	if ownerErr != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || uid != uint32(os.Geteuid()) || info.Size() != privateIntegrityKeyBytes {
		return nil, errors.Join(ownerErr, errors.New("private cleanup integrity key has unsafe metadata"))
	}
	key, err := readBoundedRootRegular(root, privateIntegrityKeyName, privateIntegrityKeyBytes)
	if err != nil {
		return nil, err
	}
	if len(key) != privateIntegrityKeyBytes {
		return nil, errors.New("private cleanup integrity key has an invalid length")
	}
	return key, nil
}

// restoreAnchoredEntry recreates one verified recovery entry without
// overwriting a concurrent target and preserves the recovery source.
func restoreAnchoredEntry(destination anchoredParent, source anchoredRecoverySource, change ReceiptItem, integrityKey []byte, operations restoreOperations) error {
	originalName := destination.leaf
	if change.Kind == "symlink" {
		target, _, err := readAnchoredSymlink(source.root, source.name)
		if err != nil {
			return fmt.Errorf("read recovery symbolic link for %s: %w", change.Original, err)
		}
		if err := operations.symlink(destination.location.root, target, originalName); err != nil {
			return fmt.Errorf("restore %s without overwrite: %w", change.Original, err)
		}
		createdTarget, created, err := readAnchoredSymlink(destination.location.root, originalName)
		if err != nil || createdTarget != target {
			return errors.Join(err, fmt.Errorf("restored symbolic link %s changed during publication", change.Original))
		}
		if err := ensureAnchoredSymlinkOwnership(destination.location.root, originalName, change.UID, change.GID); err != nil {
			return errors.Join(fmt.Errorf("restore ownership for %s: %w", change.Original, err), removeAnchoredEntryIfSame(destination.location.root, originalName, created))
		}
		if err := verifyAnchoredReceiptEntry(destination.location.root, originalName, change, integrityKey); err != nil {
			return errors.Join(fmt.Errorf("verify restored %s: %w", change.Original, err), removeAnchoredEntryIfSame(destination.location.root, originalName, created))
		}
		return syncAnchoredDirectory(destination.location.root, ".")
	}
	temporaryDirectory := ".linux-armer-restore-" + time.Now().UTC().Format("20060102T150405.000000000Z") + "-" + change.RuleID
	if err := destination.location.root.Mkdir(temporaryDirectory, 0o700); err != nil {
		return fmt.Errorf("create restoration workspace for %s: %w", change.Original, err)
	}
	workspace, err := destination.location.root.Open(temporaryDirectory)
	if err != nil {
		return fmt.Errorf("open restoration workspace for %s: %w", change.Original, err)
	}
	chmodErr := workspace.Chmod(0o700)
	syncErr := workspace.Sync()
	closeErr := workspace.Close()
	if err := errors.Join(chmodErr, syncErr, closeErr); err != nil {
		return fmt.Errorf("protect restoration workspace for %s: %w", change.Original, err)
	}
	if err := syncAnchoredDirectory(destination.location.root, "."); err != nil {
		return fmt.Errorf("persist restoration workspace for %s: %w", change.Original, err)
	}
	temporaryRoot, _, err := openStableChildRoot(destination.location.root, temporaryDirectory)
	if err != nil {
		return fmt.Errorf("anchor restoration workspace for %s: %w", change.Original, err)
	}
	defer temporaryRoot.Close()
	temporaryName := filepath.Base(originalName)
	if err := copyAnchoredEntry(source.root, source.name, temporaryRoot, temporaryName); err != nil {
		return fmt.Errorf("prepare restoration of %s: %w", change.Original, err)
	}
	if err := verifyAnchoredReceiptEntry(temporaryRoot, temporaryName, change, integrityKey); err != nil {
		return fmt.Errorf("verify prepared restoration of %s: %w", change.Original, err)
	}
	prepared, err := temporaryRoot.Lstat(temporaryName)
	if err != nil {
		return fmt.Errorf("inspect prepared restoration of %s: %w", change.Original, err)
	}
	if err := syncAnchoredDirectory(temporaryRoot, "."); err != nil {
		return fmt.Errorf("persist prepared restoration of %s: %w", change.Original, err)
	}
	temporaryFromParent := filepath.Join(temporaryDirectory, temporaryName)
	visiblePrepared, err := destination.location.root.Lstat(temporaryFromParent)
	if err != nil || !os.SameFile(prepared, visiblePrepared) {
		return errors.Join(err, fmt.Errorf("restoration workspace for %s changed before publication", change.Original))
	}
	temporaryHandle, err := temporaryRoot.Open(".")
	if err != nil {
		return fmt.Errorf("open restoration workspace descriptor for %s: %w", change.Original, err)
	}
	defer temporaryHandle.Close()
	if err := operations.link(temporaryHandle, temporaryName, destination.handle, originalName); err != nil {
		return fmt.Errorf("restore %s without overwrite: %w", change.Original, err)
	}
	published, err := destination.location.root.Lstat(originalName)
	if err != nil || !os.SameFile(prepared, published) {
		return errors.Join(err, fmt.Errorf("restored %s changed during publication", change.Original))
	}
	if err := verifyAnchoredReceiptEntryLinks(destination.location.root, originalName, change, integrityKey, 2); err != nil {
		return errors.Join(fmt.Errorf("verify restored %s: %w", change.Original, err), removeAnchoredEntryIfSame(destination.location.root, originalName, prepared))
	}
	if err := syncAnchoredDirectory(destination.location.root, "."); err != nil {
		return fmt.Errorf("persist restoration of %s: %w", change.Original, err)
	}
	removeFileErr := temporaryRoot.Remove(temporaryName)
	removeSyncErr := syncAnchoredDirectory(temporaryRoot, ".")
	visibleWorkspace, visibleErr := anchoredDirectoryIsVisible(destination.location.root, temporaryDirectory, temporaryRoot)
	finalCloseErr := temporaryRoot.Close()
	removeDirectoryErr := error(nil)
	if visibleErr == nil && visibleWorkspace {
		removeDirectoryErr = destination.location.root.Remove(temporaryDirectory)
	} else if visibleErr == nil {
		removeDirectoryErr = errors.New("restoration workspace route changed before cleanup")
	} else {
		removeDirectoryErr = visibleErr
	}
	finalSyncErr := syncAnchoredDirectory(destination.location.root, ".")
	if err := errors.Join(removeFileErr, removeSyncErr, finalCloseErr, removeDirectoryErr, finalSyncErr); err != nil {
		return fmt.Errorf("remove restoration workspace for %s: %w", change.Original, err)
	}
	return nil
}

// anchoredDirectoryIsVisible compares a held directory with the entry still
// visible through its stable parent before any pathname-based cleanup.
func anchoredDirectoryIsVisible(parent *os.Root, name string, held *os.Root) (bool, error) {
	visible, err := parent.Lstat(name)
	if err != nil {
		return false, err
	}
	opened, err := held.Stat(".")
	if err != nil {
		return false, err
	}
	return os.SameFile(visible, opened), nil
}

// removeAnchoredEntryIfSame rolls back only the exact entry created by this
// process, leaving a concurrent replacement untouched.
func removeAnchoredEntryIfSame(root *os.Root, name string, expected os.FileInfo) error {
	current, err := root.Lstat(name)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !os.SameFile(expected, current) {
		return errors.New("restored entry changed before safe rollback")
	}
	return errors.Join(root.Remove(name), syncAnchoredDirectory(root, filepath.Dir(name)))
}

// linkAnchoredDirectories creates a no-overwrite hard link between two stable
// directory descriptors without resolving either directory by pathname.
func linkAnchoredDirectories(source *os.File, sourceName string, destination *os.File, destinationName string) error {
	return unix.Linkat(int(source.Fd()), sourceName, int(destination.Fd()), destinationName, 0)
}
