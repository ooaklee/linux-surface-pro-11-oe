package ubuntu

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// installedSupportFile describes one host-staged installed-system support
// artefact and the permissions it must have in the remastered root.
type installedSupportFile struct {
	name string
	mode os.FileMode
	data string
}

// stageInstalledSupportFiles writes the bounded GRUB and kernel-refresh
// helpers that are later copied into the remastered Ubuntu root.
func stageInstalledSupportFiles(workspace, abi string) error {
	if !safeKernelABI(abi) {
		return fmt.Errorf("kernel ABI %q is not safe for installed-system support", abi)
	}
	directory := filepath.Join(workspace, "installed-support")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return fmt.Errorf("create installed-system support staging directory: %w", err)
	}
	files := []installedSupportFile{
		{name: "99-surface-pro-11.cfg", mode: 0o644, data: installedGrubDefaults()},
		{name: "09_linux_armer_sp11", mode: 0o755, data: installedGrubGenerator()},
		{name: "linux-armer-refresh-sp11-boot", mode: 0o755, data: installedBootRefresh()},
		{name: "05-linux-armer-sp11-dtb", mode: 0o755, data: installedKernelPostInstallHook()},
		{name: "05-linux-armer-sp11-dtb-remove", mode: 0o755, data: installedKernelPostRemoveHook()},
		{name: "kernel-abi", mode: 0o644, data: abi + "\n"},
	}
	for _, file := range files {
		if err := os.WriteFile(filepath.Join(directory, file.name), []byte(file.data), file.mode); err != nil {
			return fmt.Errorf("stage installed-system support file %s: %w", file.name, err)
		}
	}
	return nil
}

// installKernelPackages registers the exact image and modules packages in the
// minimal root's dpkg database while suppressing only unsafe offline hooks.
func installKernelPackages(ctx context.Context, docker *platform.Docker, image, workspace, volume string, bundle kernel.Bundle) error {
	imagePackage, ok := bundle.Package(kernel.RoleImage)
	if !ok {
		return errorsForMissingKernelRole(kernel.RoleImage)
	}
	modulesPackage, ok := bundle.Package(kernel.RoleModules)
	if !ok {
		return errorsForMissingKernelRole(kernel.RoleModules)
	}
	const script = `root=/linux-work/rootfs
abi=$1
version=$2
modules_archive=$3
image_archive=$4
modules_package="linux-modules-$abi"
image_package="linux-image-$abi"

verify_archive() {
	archive=$1
	expected_package=$2
	actual_package=$(dpkg-deb --field "$archive" Package)
	actual_version=$(dpkg-deb --field "$archive" Version)
	actual_architecture=$(dpkg-deb --field "$archive" Architecture)
	[ "$actual_package" = "$expected_package" ] || {
		echo "kernel archive $archive declares package $actual_package, expected $expected_package" >&2
		exit 65
	}
	[ "$actual_version" = "$version" ] || {
		echo "kernel archive $archive declares version $actual_version, expected $version" >&2
		exit 65
	}
	[ "$actual_architecture" = arm64 ] || {
		echo "kernel archive $archive declares architecture $actual_architecture, expected arm64" >&2
		exit 65
	}
}

verify_archive "$modules_archive" "$modules_package"
verify_archive "$image_archive" "$image_package"

backup=/linux-work/dpkg-offline-backup
[ ! -e "$backup" ] || {
	echo "refusing to reuse an existing offline dpkg backup" >&2
	exit 73
}
mkdir -m 0700 "$backup"

restore_offline_state() {
	status=$?
	for phase in preinst.d postinst.d; do
		if [ -e "$backup/$phase" ]; then
			rm -rf -- "$root/etc/kernel/$phase"
			mv "$backup/$phase" "$root/etc/kernel/$phase"
		elif [ -e "$backup/$phase.absent" ]; then
			rm -rf -- "$root/etc/kernel/$phase"
		fi
	done
	if [ -e "$backup/statoverride" ]; then
		rm -f -- "$root/var/lib/dpkg/statoverride"
		mv "$backup/statoverride" "$root/var/lib/dpkg/statoverride"
	elif [ -e "$backup/statoverride.absent" ]; then
		rm -f -- "$root/var/lib/dpkg/statoverride"
	fi
	rm -rf -- "$backup"
	trap - EXIT HUP INT TERM
	exit "$status"
}
trap restore_offline_state EXIT HUP INT TERM

for phase in preinst.d postinst.d; do
	if [ -e "$root/etc/kernel/$phase" ]; then
		mv "$root/etc/kernel/$phase" "$backup/$phase"
	else
		: > "$backup/$phase.absent"
	fi
	mkdir -p "$root/etc/kernel/$phase"
done

# The minimal layer's statoverride database names accounts supplied by upper
# Casper layers. Hide it only while these kernel archives are installed, then
# restore the original bytes even when dpkg or an interrupt stops the build.
if [ -e "$root/var/lib/dpkg/statoverride" ]; then
	mv "$root/var/lib/dpkg/statoverride" "$backup/statoverride"
	else
	: > "$backup/statoverride.absent"
fi
: > "$root/var/lib/dpkg/statoverride"

# Offline kernel hooks expect mounted target devices and may generate an
# unsuitable live initramfs. Package scripts still register their exact files;
# the distro's initramfs command runs separately after support is installed.
dpkg --root="$root" --install "$modules_archive" "$image_archive"

chroot "$root" dpkg-query --show --showformat='${Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n' \
	"$modules_package" "$image_package" > /linux-work/kernel-package-status
expected_modules=$(printf '%s\t%s\tarm64\tinstalled' "$modules_package" "$version")
expected_image=$(printf '%s\t%s\tarm64\tinstalled' "$image_package" "$version")
grep -Fx "$expected_modules" /linux-work/kernel-package-status >/dev/null
grep -Fx "$expected_image" /linux-work/kernel-package-status >/dev/null
`
	if err := docker.RunInWorkspaceVolume(ctx, image, workspace, volume,
		"bash", "-ceu", script, "linux-armer-install-kernel", bundle.ABI, bundle.Version,
		"/work/kernel/"+modulesPackage.Name, "/work/kernel/"+imagePackage.Name); err != nil {
		return fmt.Errorf("register custom kernel packages in remastered root: %w", err)
	}
	return nil
}

// errorsForMissingKernelRole returns a consistent error for an incomplete
// kernel bundle passed to the installed-system hand-off.
func errorsForMissingKernelRole(role kernel.PackageRole) error {
	return fmt.Errorf("kernel bundle has no %s package", role)
}

// installInstalledSystemSupport copies deterministic X1E and X1P boot support
// into the live root and prepares a non-Casper initramfs for the installed OS.
func installInstalledSystemSupport(ctx context.Context, docker *platform.Docker, image, workspace, volume string, bundle kernel.Bundle) error {
	const script = `root=/linux-work/rootfs
abi=$1
support=/work/installed-support

install -d -m 0755 \
	"$root/etc/default/grub.d" \
	"$root/etc/grub.d" \
	"$root/etc/kernel/postinst.d" \
	"$root/etc/kernel/postrm.d" \
	"$root/usr/local/sbin" \
	"$root/usr/lib/linux-armer/sp11/dtb"
install -m 0644 "$support/99-surface-pro-11.cfg" "$root/etc/default/grub.d/99-surface-pro-11.cfg"
install -m 0755 "$support/09_linux_armer_sp11" "$root/etc/grub.d/09_linux_armer_sp11"
install -m 0755 "$support/linux-armer-refresh-sp11-boot" "$root/usr/local/sbin/linux-armer-refresh-sp11-boot"
install -m 0755 "$support/05-linux-armer-sp11-dtb" "$root/etc/kernel/postinst.d/05-linux-armer-sp11-dtb"
install -m 0755 "$support/05-linux-armer-sp11-dtb-remove" "$root/etc/kernel/postrm.d/05-linux-armer-sp11-dtb"
install -m 0644 "$support/kernel-abi" "$root/usr/lib/linux-armer/sp11/kernel-abi"

for name in x1e80100-microsoft-denali-oled.dtb x1p64100-microsoft-denali.dtb; do
	source="$root/usr/lib/firmware/$abi/device-tree/qcom/$name"
	[ -s "$source" ] || {
		echo "installed-system hand-off is missing $source" >&2
		exit 66
	}
	install -m 0644 "$source" "$root/usr/lib/linux-armer/sp11/dtb/$name"
done

chroot "$root" /usr/local/sbin/linux-armer-refresh-sp11-boot "$abi"
test -x "$root/usr/sbin/update-initramfs"
rm -f -- "$root/boot/initrd.img-$abi"
chroot "$root" update-initramfs -c -k "$abi"
test -s "$root/boot/initrd.img-$abi"
`
	if err := docker.RunInWorkspaceVolume(ctx, image, workspace, volume,
		"bash", "-ceu", script, "linux-armer-installed-support", bundle.ABI); err != nil {
		return fmt.Errorf("install installed-system kernel, DTB, GRUB, and initramfs support: %w", err)
	}
	return nil
}

// installedGrubDefaults returns the installed operating system's Surface
// command line without the live-media-only USB safety blacklist.
func installedGrubDefaults() string {
	return `# Surface Pro 11 platform arguments for installed kernels.
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} clk_ignore_unused pd_ignore_unused arm64.nopauth systemd.tpm2_wait=0 soundwire_qcom.sp11_feedback_active_offset2_zero=1"
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=15
`
}

// installedGrubGenerator returns a bounded GRUB generator with explicit X1E
// and X1P entries for each installed Surface kernel and its paired initramfs.
func installedGrubGenerator() string {
	return `#!/bin/sh
set -eu

. "${pkgdatadir}/grub-mkconfig_lib"

is_safe_abi() {
	case "$1" in
		""|*[!A-Za-z0-9.+_~-]*) return 1 ;;
		*) return 0 ;;
	esac
}

relative_boot=$(make_system_path_relative_to_its_root /boot)
[ "$relative_boot" != / ] || relative_boot=
boot_device=${GRUB_DEVICE_BOOT:-${GRUB_DEVICE:-}}
[ -n "$boot_device" ] || exit 0
if [ -n "${GRUB_DEVICE_UUID:-}" ]; then
	root_argument="root=UUID=${GRUB_DEVICE_UUID}"
elif [ -n "${GRUB_DEVICE:-}" ]; then
	root_argument="root=${GRUB_DEVICE}"
else
	exit 0
fi

for kernel in $(find /boot -maxdepth 1 -type f -name 'vmlinuz-*-qcom-x1e' -printf '%f\n' | LC_ALL=C sort -Vr); do
	abi=${kernel#vmlinuz-}
	is_safe_abi "$abi" || continue
	initrd="/boot/initrd.img-$abi"
	x1e="/boot/dtbs/$abi/qcom/x1e80100-microsoft-denali-oled.dtb"
	x1p="/boot/dtbs/$abi/qcom/x1p64100-microsoft-denali.dtb"
	[ -s "$initrd" ] && [ -s "$x1e" ] && [ -s "$x1p" ] || continue

	kernel_path="$relative_boot/vmlinuz-$abi"
	initrd_path="$relative_boot/initrd.img-$abi"
	for model in x1e x1p; do
		case "$model" in
			x1e)
				title="Linux Armer Surface Pro 11 X1E/OLED ($abi)"
				dtb_path="$relative_boot/dtbs/$abi/qcom/x1e80100-microsoft-denali-oled.dtb"
				;;
			x1p)
				title="Linux Armer Surface Pro 11 X1P/LCD ($abi)"
				dtb_path="$relative_boot/dtbs/$abi/qcom/x1p64100-microsoft-denali.dtb"
				;;
		esac
		printf "menuentry '%s' --class ubuntu --class gnu-linux --class os {\n" "$(printf '%s' "$title" | grub_quote)"
		prepare_grub_to_access_device "$boot_device" | sed 's/^/    /'
		printf '    linux %s %s ro %s %s\n' "$kernel_path" "$root_argument" "${GRUB_CMDLINE_LINUX:-}" "${GRUB_CMDLINE_LINUX_DEFAULT:-}"
		printf '    devicetree %s\n' "$dtb_path"
		printf '    initrd %s\n' "$initrd_path"
		printf '}\n'
	done
done
`
}

// installedBootRefresh returns the bounded helper that copies only paired
// Surface DTBs for one safe installed kernel ABI into its versioned boot path.
func installedBootRefresh() string {
	return `#!/bin/sh
set -eu

is_safe_abi() {
	case "$1" in
		""|*[!A-Za-z0-9.+_~-]*) return 1 ;;
		*) return 0 ;;
	esac
}

seed_abi=$(cat /usr/lib/linux-armer/sp11/kernel-abi)
is_safe_abi "$seed_abi" || {
	echo "linux-armer seed kernel ABI is invalid" >&2
	exit 65
}

requested=${1:-}
if is_safe_abi "$requested" && [ -s "/boot/vmlinuz-$requested" ]; then
	abi=$requested
else
	abi=
	for kernel in $(find /boot -maxdepth 1 -type f -name 'vmlinuz-*-qcom-x1e' -printf '%f\n' | LC_ALL=C sort -Vr); do
		candidate=${kernel#vmlinuz-}
		if is_safe_abi "$candidate"; then
			abi=$candidate
			break
		fi
	done
fi
[ -n "$abi" ] || exit 0

destination="/boot/dtbs/$abi/qcom"
install -d -m 0755 "$destination"
for name in x1e80100-microsoft-denali-oled.dtb x1p64100-microsoft-denali.dtb; do
	source=
	for candidate in \
		"/usr/lib/firmware/$abi/device-tree/qcom/$name" \
		"/usr/lib/linux-image-$abi/qcom/$name"; do
		if [ -s "$candidate" ]; then
			source=$candidate
			break
		fi
	done
	if [ -z "$source" ] && [ "$abi" = "$seed_abi" ]; then
		candidate="/usr/lib/linux-armer/sp11/dtb/$name"
		[ ! -s "$candidate" ] || source=$candidate
	fi
	[ -n "$source" ] || {
		echo "no paired Surface Pro 11 DTB named $name for kernel $abi" >&2
		exit 66
	}
	install -m 0644 "$source" "$destination/$name"
done
`
}

// installedKernelPostInstallHook returns the small lifecycle hook that refreshes
// versioned DTBs before Ubuntu's normal GRUB hook generates its menu.
func installedKernelPostInstallHook() string {
	return `#!/bin/sh
set -eu
exec /usr/local/sbin/linux-armer-refresh-sp11-boot "${1:-}"
`
}

// installedKernelPostRemoveHook returns the bounded removal hook that deletes
// only the DTB directory belonging to the exact safe kernel ABI being removed.
func installedKernelPostRemoveHook() string {
	return `#!/bin/sh
set -eu
abi=${1:-}
case "$abi" in
	""|*[!A-Za-z0-9.+_~-]*) exit 0 ;;
esac
rm -rf -- "/boot/dtbs/$abi"
`
}

// installedPackageNames returns the exact Debian package names expected for a
// Surface kernel ABI, in modules-first installation order.
func installedPackageNames(abi string) []string {
	return []string{"linux-modules-" + abi, "linux-image-" + abi}
}

// installedSupportPaths returns the ABI-bound live-root paths that validation
// must extract before it can assess the installed-system hand-off.
func installedSupportPaths(abi string) []string {
	paths := []string{
		"boot/vmlinuz-" + abi,
		"boot/initrd.img-" + abi,
		"boot/dtbs/" + abi + "/qcom/x1e80100-microsoft-denali-oled.dtb",
		"boot/dtbs/" + abi + "/qcom/x1p64100-microsoft-denali.dtb",
		"etc/default/grub.d/99-surface-pro-11.cfg",
		"etc/grub.d/09_linux_armer_sp11",
		"etc/kernel/postinst.d/05-linux-armer-sp11-dtb",
		"etc/kernel/postrm.d/05-linux-armer-sp11-dtb",
		"usr/local/sbin/linux-armer-refresh-sp11-boot",
		"usr/lib/linux-armer/sp11/kernel-abi",
		"usr/lib/linux-armer/sp11/dtb/x1e80100-microsoft-denali-oled.dtb",
		"usr/lib/linux-armer/sp11/dtb/x1p64100-microsoft-denali.dtb",
		"var/lib/dpkg/status",
	}
	for _, packageName := range installedPackageNames(abi) {
		paths = append(paths, "var/lib/dpkg/info/"+packageName+".list")
	}
	return paths
}

// installedPackageStatus reports whether one exact package stanza is marked as
// installed for the expected version and ARM64 architecture.
func installedPackageStatus(status, packageName, version string) bool {
	for _, paragraph := range strings.Split(strings.ReplaceAll(status, "\r\n", "\n"), "\n\n") {
		fields := make(map[string]string)
		for _, line := range strings.Split(paragraph, "\n") {
			key, value, ok := strings.Cut(line, ":")
			if ok {
				fields[key] = strings.TrimSpace(value)
			}
		}
		if fields["Package"] == packageName && fields["Version"] == version &&
			fields["Architecture"] == "arm64" && fields["Status"] == "install ok installed" {
			return true
		}
	}
	return false
}
