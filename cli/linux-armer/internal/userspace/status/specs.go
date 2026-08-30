package status

// maxPinnedFileBytes is the fail-closed hashing ceiling for a pinned file that
// does not have a narrower compiled asset-size contract.
const maxPinnedFileBytes int64 = 64 << 20

// fileRequirement describes one static filesystem contract, including optional
// identity, executable-bit, and safe symlink requirements.
type fileRequirement struct {
	// Path is the logical path relative to the inspected target root.
	Path string
	// SHA256 pins content identity when an exact companion asset is required.
	SHA256 string
	// ExpectedSize pins exact byte length when release metadata provides it.
	ExpectedSize int64
	// MaximumSize narrows the safe hashing ceiling for a particular asset class.
	MaximumSize int64
	// Executable requires at least one execute permission bit.
	Executable bool
	// AllowSymlink permits a leaf link resolved within the target root.
	AllowSymlink bool
}

// platformFirmware lists the proprietary Qualcomm and device firmware files
// required for the Surface platform subsystems.
var platformFirmware = []fileRequirement{
	{Path: "lib/firmware/qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn"},
	{Path: "lib/firmware/qcom/x1e80100/microsoft/qcdxkmsucpurwa.mbn"},
	{Path: "lib/firmware/qcom/x1e80100/microsoft/Denali/adsp_dtb.mbn"},
	{Path: "lib/firmware/qcom/x1e80100/microsoft/Denali/qcadsp8380.mbn"},
	{Path: "lib/firmware/qcom/x1e80100/microsoft/Denali/adspr.jsn"},
	{Path: "lib/firmware/qcom/x1e80100/microsoft/Denali/adsps.jsn"},
	{Path: "lib/firmware/qcom/x1e80100/microsoft/Denali/adspua.jsn"},
	{Path: "lib/firmware/qcom/x1e80100/microsoft/Denali/battmgr.jsn"},
	{Path: "lib/firmware/qcom/x1e80100/microsoft/Denali/cdsp_dtb.mbn"},
	{Path: "lib/firmware/qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn"},
	{Path: "lib/firmware/qcom/x1e80100/microsoft/Denali/cdspr.jsn"},
}

// denaliGPULink is the firmware lookup alias whose exact relative link target is
// validated separately.
const denaliGPULink = "lib/firmware/qcom/x1e80100/microsoft/Denali/qcdxkmsuc8380.mbn"

// wcn7850Firmware groups each required Wi-Fi firmware file with its accepted
// compressed variants.
var wcn7850Firmware = [][]fileRequirement{
	compressedAlternatives("lib/firmware/ath12k/WCN7850/hw2.0/amss.bin"),
	compressedAlternatives("lib/firmware/ath12k/WCN7850/hw2.0/m3.bin"),
	compressedAlternatives("lib/firmware/ath12k/WCN7850/hw2.0/board-2.bin"),
	compressedAlternatives("lib/firmware/ath12k/WCN7850/hw2.0/regdb.bin"),
}

// wifiBoardData describes the conditional legacy board-data fallback, which is
// reported separately from the preferred board-2 database.
var wifiBoardData = compressedAlternatives("lib/firmware/ath12k/WCN7850/hw2.0/board.bin")

// bluetoothFirmware groups the WCN7850 Bluetooth payloads with accepted
// compressed variants.
var bluetoothFirmware = [][]fileRequirement{
	compressedAlternatives("lib/firmware/qca/hmtbtfw20.tlv"),
	compressedAlternatives("lib/firmware/qca/hmtnv20.bin"),
}

// bluetoothBlueZFiles accepts supported distribution locations for the BlueZ
// daemon and its service unit.
var bluetoothBlueZFiles = [][]fileRequirement{
	{
		{Path: "usr/libexec/bluetooth/bluetoothd", Executable: true},
		{Path: "usr/lib/bluetooth/bluetoothd", Executable: true},
	},
	{
		{Path: "usr/lib/systemd/system/bluetooth.service"},
		{Path: "lib/systemd/system/bluetooth.service"},
	},
}

// bluetoothHookFiles describes the complete optional, bounded public-address
// integration without reading or recording the private address value.
var bluetoothHookFiles = []fileRequirement{
	{Path: "etc/default/sp11-bluetooth-mac"},
	{Path: "usr/local/sbin/sp11-bt-set-addr", Executable: true},
	{Path: "etc/systemd/system/sp11-bluetooth-mac@.service"},
	{Path: "etc/udev/rules.d/99-surface-pro-11-bluetooth-mac.rules"},
}

// audioV19cFiles pins the complete FullIO v19c topology and UCM asset identities
// so partial or mixed revisions cannot pass inspection.
var audioV19cFiles = []fileRequirement{
	{Path: "lib/firmware/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin", SHA256: "e7bb06a03e7bd9b869825a51775355a6743477d1579d78eb09fad5881cfb20f0", ExpectedSize: 35128},
	{Path: "usr/share/alsa/ucm2/Qualcomm/x1e80100/MICROSOFT-Surface-Pro-11in.conf", SHA256: "225976f925624f156d9fab84e15a5126a60a236783cfcb82d43d2a2aec028d7b", ExpectedSize: 2923},
	{Path: "usr/share/alsa/ucm2/Qualcomm/x1e80100/SP11-HiFi.conf", SHA256: "9d36df8570b85f1dcecc385a8f85fa2d1e1058ef8efedee6ae2ce49dc259a06a", ExpectedSize: 9391},
	{Path: "usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf", SHA256: "e5cc331a77d28b3844f58e49d3c75b836a25378292fac24be692a8d26c3b5b16", ExpectedSize: 1371},
}

// legacyAudioPaths enumerates recognised retired routing and UCM workarounds
// that conflict with the current kernel and FullIO bundle.
var legacyAudioPaths = []string{
	"etc/systemd/system/sp11-wsa-routing.service",
	"etc/systemd/system/multi-user.target.wants/sp11-wsa-routing.service",
	"usr/local/sbin/sp11-enable-wsa-routing",
	"usr/local/sbin/sp11-enable-wsa-routing.sh",
	"usr/local/sbin/sp11-fix-audio-boot-race",
	"etc/pipewire/pipewire.conf.d/50-sp11-speakers.conf",
	"usr/share/alsa/ucm2/Qualcomm/x1e80100/Surface11-HiFi.conf",
	"usr/share/alsa/ucm2/Qualcomm/x1e80100/MICROSOFT-Surface-Pro-11.conf",
}

// iptsdV1Files pins the supported daemon, checker, configuration, and integration
// file identities as one inseparable userspace contract.
var iptsdV1Files = []fileRequirement{
	{Path: "usr/local/libexec/sp11-iptsd", SHA256: "f6a908e9515c4ccbed48c327445aa7924d4344129d9eb016690bdd056b52d009", ExpectedSize: 1269968, Executable: true},
	{Path: "usr/local/libexec/sp11-iptsd-check-device", SHA256: "f5a274a250349fac0f9e8cf781585ae5d97a73cf281cc778b7e9cf6012f5378a", ExpectedSize: 1269672, Executable: true},
	{Path: "usr/local/share/iptsd/surface-pro-11-0c80.conf", SHA256: "e629f67248df412d69952accc874b848e3e45ad3d8b31cbec4626f85c12c8c34"},
	{Path: "usr/local/share/iptsd/surface-pro-11-0c83.conf", SHA256: "358953d2171b36879043dc46084cc9344ea2c28cc718ff75690acd479214bf59"},
	{Path: "etc/systemd/system/sp11-iptsd@.service", SHA256: "74add71ef414c09547434db92e3f3faeee5909a8181dd28317d9d54cd77f2e4a"},
	{Path: "etc/udev/rules.d/70-sp11-iptsd.rules", SHA256: "2723ddfa7afb431368fce31419cb77b97853286ac37fd824d418e5c3bc8e2327"},
	{Path: "usr/lib/systemd/system-sleep/sp11-iptsd-restart", SHA256: "9a81548cef754a1ed933ad2c6f540ca916e6101848c1616402bbe355232ac102", Executable: true},
}

// genericIPTSDMask identifies the generic service that must be masked so it does
// not contend with the device-specific SP11 bridge.
const genericIPTSDMask = "etc/systemd/system/iptsd@.service"

// g6PenPaths lists diagnostic-only tooling that can conflict with IPTSD when
// enabled or run concurrently.
var g6PenPaths = []string{
	"usr/sbin/g6-pen",
	"etc/g6-pen.conf",
	"etc/systemd/system/g6-pen.service",
}

// g6PenEnabledPath identifies the static enablement link that makes the
// diagnostic tool a readiness-blocking IPTSD conflict.
const g6PenEnabledPath = "etc/systemd/system/multi-user.target.wants/g6-pen.service"

// obsoleteTouchscreenPaths identify fixed integration files left by the retired
// out-of-tree touchscreen installer. ABI-specific override modules and release
// markers are discovered separately.
var obsoleteTouchscreenPaths = []string{
	"etc/modprobe.d/sp11-touchscreen.conf",
	"etc/modules-load.d/sp11-touchscreen.conf",
	"etc/initramfs-tools/hooks/sp11-touchscreen",
	"etc/dracut.conf.d/91-sp11-touchscreen.conf",
	"usr/lib/dracut/modules.d/90sp11-touchscreen/module-setup.sh",
}

// obsoleteTouchscreenModulePaths are the exact updates-tree overrides installed
// by the superseded touchscreen workflow for each kernel ABI.
var obsoleteTouchscreenModulePaths = []string{
	"updates/drivers/dma/qcom/gpi.ko",
	"updates/drivers/spi/spi-geni-qcom.ko",
	"updates/drivers/input/touchscreen/mshw0485_touch.ko",
}

// cameraPackageVersion is the exact tested version shared by the supported five
// package IMX681 libcamera set.
const cameraPackageVersion = "0.7.0-1ubuntu2+sp11.1.20260829040923655984892.cf8d1a113b7f11ccfea732c24299cd43"

// cameraPackages names every arm64 package that must be installed together for
// the optional IMX681 camera integration.
var cameraPackages = []string{
	"libcamera0.7",
	"libcamera-ipa",
	"libcamera-tools",
	"libcamera-v4l2",
	"gstreamer1.0-libcamera",
}

// cameraFiles checks the camera IPA module, signature, sensor configuration, and
// verifier that distinguish the supported package build.
var cameraFiles = []fileRequirement{
	{Path: "usr/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so"},
	{Path: "usr/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so.sign"},
	{Path: "usr/share/libcamera/ipa/simple/imx681.yaml", SHA256: "c540892490f2f671decd83ac41f96d4208f27e7e520a1b47e46004e3a88f7b6a"},
	{Path: "usr/bin/ipa_verify", Executable: true},
}

// powerProfileFiles accepts the supported distribution locations for the
// optional power-profile client and service.
var powerProfileFiles = [][]fileRequirement{
	{{Path: "usr/bin/powerprofilesctl", Executable: true}},
	{
		{Path: "usr/lib/systemd/system/power-profiles-daemon.service"},
		{Path: "lib/systemd/system/power-profiles-daemon.service"},
	},
}

// compressedAlternatives expands one logical firmware path into the uncompressed,
// Zstandard, and XZ forms commonly shipped by distributions.
func compressedAlternatives(path string) []fileRequirement {
	return []fileRequirement{
		{Path: path, AllowSymlink: true},
		{Path: path + ".zst", AllowSymlink: true},
		{Path: path + ".xz", AllowSymlink: true},
	}
}
