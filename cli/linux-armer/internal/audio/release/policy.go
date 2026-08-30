package release

const (
	// SupportedTag is the reviewed FullIO v19c release identity.
	SupportedTag = "sp11-audio-v19c"
	// SourceRelease identifies the reviewed upstream deployment release.
	SourceRelease = "native-audio-fullio-v19c-20260826"
	// SourceRevision identifies the reviewed upstream source commit.
	SourceRevision = "7af8f21e9966f6f6adb40c102653b6acb5d81742"
	// TopologyName is the public installable FullIO topology basename.
	TopologyName = "X1E80100-Microsoft-Surface-Pro-11-tplg.bin"
	// CardUCMName is the public Surface Pro 11 card-profile basename.
	CardUCMName = "MICROSOFT-Surface-Pro-11in.conf"
	// HiFiUCMName is the public Surface Pro 11 HiFi verb basename.
	HiFiUCMName = "SP11-HiFi.conf"
	// MatcherName is the generated DMI matcher basename.
	MatcherName = "x1e80100.conf"
)

// sourceSpec binds one reviewed source path to its role and output identity.
type sourceSpec struct {
	// role is the stable semantic source purpose.
	role string
	// relativePath is the fixed slash-separated path beneath SourceRoot.
	relativePath string
	// releaseName is the output basename, or empty for generation-only input.
	releaseName string
	// sha256 is the pinned complete source digest.
	sha256 string
	// expectedSize is the required size when positive.
	expectedSize int64
}

// artefactSpec binds one release basename to its reviewed digest and size.
type artefactSpec struct {
	// name is the fixed portable release basename.
	name string
	// sha256 is the pinned complete release digest.
	sha256 string
	// size is the required complete byte length.
	size int64
}

// policy contains the complete immutable v19c release contract.
type policy struct {
	// tag is the only accepted release identity.
	tag string
	// sourceRelease identifies the reviewed upstream deployment release.
	sourceRelease string
	// sourceRevision identifies the reviewed upstream commit.
	sourceRevision string
	// checksumRelativePath is the fixed source checksum-manifest path.
	checksumRelativePath string
	// sources contains all role-specific pinned inputs in output order.
	sources []sourceSpec
	// artefacts contains all four exact release outputs in checksum order.
	artefacts []artefactSpec
	// checksum identifies the exact deterministic generated SHA256SUMS.
	checksum artefactSpec
}

// productionPolicy returns the reviewed FullIO v19c source and output pins.
func productionPolicy() policy {
	return policy{
		tag:                  SupportedTag,
		sourceRelease:        SourceRelease,
		sourceRevision:       SourceRevision,
		checksumRelativePath: "deploy/native-audio-v19c/SHA256SUMS",
		sources: []sourceSpec{
			{role: "topology", relativePath: "deploy/native-audio-v19c/X1E80100-Microsoft-Surface-Pro-11-FullIO-v19c0-tplg.bin", releaseName: TopologyName, sha256: "e7bb06a03e7bd9b869825a51775355a6743477d1579d78eb09fad5881cfb20f0", expectedSize: 35128},
			{role: "card-ucm", relativePath: "deploy/ucm2/Qualcomm/x1e80100/MICROSOFT-Surface-Pro-11in.conf", releaseName: CardUCMName, sha256: "225976f925624f156d9fab84e15a5126a60a236783cfcb82d43d2a2aec028d7b", expectedSize: 2923},
			{role: "hifi-ucm", relativePath: "deploy/ucm2/Qualcomm/x1e80100/SP11-HiFi.conf", releaseName: HiFiUCMName, sha256: "9d36df8570b85f1dcecc385a8f85fa2d1e1058ef8efedee6ae2ce49dc259a06a", expectedSize: 9391},
			{role: "matcher-base", relativePath: "deploy/ucm2/Qualcomm/x1e80100/x1e80100.conf.upstream-1.2.15.3-1ubuntu1.4", sha256: "cb2e60f2b95b5d7841de5f0c914091422b2a3ecff02430ad1cc0c1d468896505"},
		},
		artefacts: []artefactSpec{
			{name: TopologyName, sha256: "e7bb06a03e7bd9b869825a51775355a6743477d1579d78eb09fad5881cfb20f0", size: 35128},
			{name: CardUCMName, sha256: "225976f925624f156d9fab84e15a5126a60a236783cfcb82d43d2a2aec028d7b", size: 2923},
			{name: HiFiUCMName, sha256: "9d36df8570b85f1dcecc385a8f85fa2d1e1058ef8efedee6ae2ce49dc259a06a", size: 9391},
			{name: MatcherName, sha256: "e5cc331a77d28b3844f58e49d3c75b836a25378292fac24be692a8d26c3b5b16", size: 1371},
		},
		checksum: artefactSpec{name: ChecksumName, sha256: "e490d2ca28278442f12d376b579db13b2b46060b28c7e040b67370161c8588f2", size: 368},
	}
}
