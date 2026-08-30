package install

import userspacepolicy "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/policy"

// userspaceRepository is the sole trusted publisher for pinned bundles.
const userspaceRepository = userspacepolicy.IPTSDRepository

// immutableFile binds one release filename to its exact content and length.
type immutableFile struct {
	name   string
	sha256 string
	size   int64
}

// releaseSpec is the compiled trust policy for one installable component.
type releaseSpec struct {
	component string
	tag       string
	files     []immutableFile
}

// audioSpec pins every checksummed member of the v19c audio release.
var audioSpec = releaseSpec{
	component: AudioComponent,
	tag:       "sp11-audio-v19c",
	files: []immutableFile{
		{name: "SHA256SUMS", sha256: "e490d2ca28278442f12d376b579db13b2b46060b28c7e040b67370161c8588f2", size: 368},
		{name: "MICROSOFT-Surface-Pro-11in.conf", sha256: "225976f925624f156d9fab84e15a5126a60a236783cfcb82d43d2a2aec028d7b", size: 2923},
		{name: "SP11-HiFi.conf", sha256: "9d36df8570b85f1dcecc385a8f85fa2d1e1058ef8efedee6ae2ce49dc259a06a", size: 9391},
		{name: "X1E80100-Microsoft-Surface-Pro-11-tplg.bin", sha256: "e7bb06a03e7bd9b869825a51775355a6743477d1579d78eb09fad5881cfb20f0", size: 35128},
		{name: "x1e80100.conf", sha256: "e5cc331a77d28b3844f58e49d3c75b836a25378292fac24be692a8d26c3b5b16", size: 1371},
	},
}

// iptsdSpec pins the complete source-bearing pen integration release.
var iptsdSpec = releaseSpecFromPolicy(userspacepolicy.IPTSDRelease())

// releaseSpecFromPolicy projects one shared immutable userspace contract into
// the installer's private representation.
func releaseSpecFromPolicy(contract userspacepolicy.Release) releaseSpec {
	spec := releaseSpec{component: contract.Component, tag: contract.Tag, files: make([]immutableFile, len(contract.Artifacts))}
	for index, artifact := range contract.Artifacts {
		spec.files[index] = immutableFile{name: artifact.Name, sha256: artifact.SHA256, size: artifact.Size}
	}
	return spec
}

// cameraVersion is the only package generation accepted by this build.
const cameraVersion = "0.7.0-1ubuntu2+sp11.1.20260829040923655984892.cf8d1a113b7f11ccfea732c24299cd43"

// cameraRuntimeFiles lists the five packages installed in one transaction.
var cameraRuntimeFiles = []immutableFile{
	{name: "libcamera0.7_" + cameraVersion + "_arm64.deb", sha256: "6e6c2c4bbeea50e163761a4b6008690a114b83f1b0c8398964a88f0c64104112", size: 749074},
	{name: "libcamera-ipa_" + cameraVersion + "_arm64.deb", sha256: "dfbfafbe733494b0ebe8ada1c3e51e4b547484edb591018364f83de6692bb32e", size: 779710},
	{name: "libcamera-tools_" + cameraVersion + "_arm64.deb", sha256: "2ce605dca91a38cbe1d19fd3382951b8b55eaa12d9be3e4f01b4c973307739f0", size: 352666},
	{name: "libcamera-v4l2_" + cameraVersion + "_arm64.deb", sha256: "0cbc35a31917afdeb3bd7412ef761d33df76cdb28de7c365981f7056925a8be3", size: 47774},
	{name: "gstreamer1.0-libcamera_" + cameraVersion + "_arm64.deb", sha256: "327308a714e814b24211f08ee2e879ab491eba1163764103a5e521f0fbe9e947", size: 65920},
}

// cameraSpec pins runtime packages and their corresponding provenance files.
var cameraSpec = releaseSpec{
	component: CameraComponent,
	tag:       "sp11-imx681-libcamera-v1",
	files: append([]immutableFile{
		{name: "SHA256SUMS", sha256: "4820883c2613c70ac0cc2ea5e51231983efa96235da78ac56b66c28d0912bad7", size: 1303},
		{name: "libcamera_" + cameraVersion + "_arm64.buildinfo", sha256: "351cbacc3ada92df4b8ca971758562ea5438eeef4e05acf6d0d81d1656046c15", size: 23924},
		{name: "libcamera_" + cameraVersion + "_arm64.changes", sha256: "f126d4be4bd2b57c643fc811d1c10fb7b4a3fba0c0c5c7012f8fc70c19cb9fad", size: 8352},
		{name: "sp11-imx681-libcamera-build-manifest.txt", sha256: "c3db097fafdb7e4e11f6d17281d105e51f1fdc1668f0d4e9846ec778e1f23d38", size: 6594},
	}, cameraRuntimeFiles...),
}
