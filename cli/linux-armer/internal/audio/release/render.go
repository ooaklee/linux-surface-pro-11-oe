package release

import (
	"bytes"
	"errors"
	"fmt"
	"sort"
	"strings"
)

// matcherBranch is the exact Surface Pro 11 DMI selection block.
const matcherBranch = `
If.SURFACEPro11in {
	Condition {
		Type RegexMatch
		String "${var:DMI_info}"
		Regex "Microsoft Corporation.*Surface.*Microsoft Surface Pro, 11th Edition"
	}
	True.Include.sp11.File "/Qualcomm/x1e80100/MICROSOFT-Surface-Pro-11in.conf"
}
`

// generateMatcher reproduces the reviewed single-anchor UCM matcher transform.
func generateMatcher(base []byte) ([]byte, error) {
	if len(base) == 0 || int64(len(base)) > maximumTextBytes || bytes.IndexByte(base, 0) >= 0 {
		return nil, errors.New("matcher base must be bounded, non-empty text")
	}
	if bytes.Contains(base, []byte("If.SURFACEPro11")) {
		return nil, errors.New("matcher base already contains a Surface Pro 11 branch")
	}
	lines := bytes.Split(base, []byte{'\n'})
	if len(lines) > 0 && len(lines[len(lines)-1]) == 0 {
		lines = lines[:len(lines)-1]
	}
	anchor := -1
	for index, line := range lines {
		if len(line) > 64*1024 {
			return nil, errors.New("matcher base contains an overlong line")
		}
		if bytes.Contains(line, []byte("Define.DMI_info")) {
			if anchor >= 0 {
				return nil, errors.New("matcher base must contain exactly one Define.DMI_info line")
			}
			anchor = index
		}
	}
	if anchor < 0 {
		return nil, errors.New("matcher base must contain exactly one Define.DMI_info line")
	}
	var output bytes.Buffer
	for index, line := range lines {
		output.Write(line)
		output.WriteByte('\n')
		if index == anchor {
			output.WriteString(matcherBranch)
		}
	}
	if int64(output.Len()) > maximumTextBytes {
		return nil, errors.New("generated matcher exceeds its size limit")
	}
	return output.Bytes(), nil
}

// renderChecksums emits the four installable artefact identities in policy order.
func renderChecksums(artefacts []FileRecord) ([]byte, error) {
	if len(artefacts) != 4 {
		return nil, errors.New("exactly four installable audio artefacts are required")
	}
	var output strings.Builder
	for _, artefact := range artefacts {
		if !safePortableName(artefact.Name) || !digestExpression.MatchString(artefact.SHA256) || artefact.Size <= 0 {
			return nil, errors.New("cannot render a malformed audio artefact checksum")
		}
		fmt.Fprintf(&output, "%s  %s\n", artefact.SHA256, artefact.Name)
	}
	return []byte(output.String()), nil
}

// renderNotes emits deterministic British-English release and install guidance.
func renderNotes(manifest Manifest) []byte {
	inputs := append([]SourceInput(nil), manifest.Source.Inputs...)
	sort.Slice(inputs, func(first, second int) bool { return inputs[first].Role < inputs[second].Role })
	var sourceLines strings.Builder
	for _, input := range inputs {
		fmt.Fprintf(&sourceLines, "- %s source `%s`: `%s`\n", input.Role, input.File.Name, input.File.SHA256)
	}
	template := "# Surface Pro 11 FullIO v19c audio\n\n" +
		"This closed local release contains the reviewed AudioReach FullIO v19c topology\n" +
		"and matching ALSA UCM configuration for the Microsoft Surface Pro 11\n" +
		"(X1E80100). It is paired explicitly with kernel release `%s` and installed ABI\n" +
		"`%s` (Surface generation sp11v%d).\n\n" +
		"## Artefact set\n\n" +
		"- `%s` — FullIO v19c topology for `/lib/firmware/qcom/x1e80100/`.\n" +
		"- `%s` — Surface Pro 11 UCM card profile.\n" +
		"- `%s` — HiFi speaker and microphone verb.\n" +
		"- `%s` — generated DMI matcher selecting the card profile.\n" +
		"- `%s` — SHA-256 identities for the four installable artefacts.\n" +
		"- `%s` — path-free structured local preparation authority.\n\n" +
		"## Verify and install\n\n" +
		"Run `sha256sum -c SHA256SUMS` in this directory before installation. Install the\n" +
		"topology beneath `/lib/firmware/qcom/x1e80100/`, the card and HiFi files beneath\n" +
		"`/usr/share/alsa/ucm2/Qualcomm/x1e80100/`, and the matcher beneath\n" +
		"`/usr/share/alsa/ucm2/conf.d/x1e80100/`. Reboot after installation because q6apm\n" +
		"requests the topology while the ASoC component probes.\n\n" +
		"## Provenance\n\n" +
		"- source release: `%s`\n" +
		"- source revision: `%s`\n" +
		"- source checksum manifest: `%s` (`%s`)\n" +
		"%s\n" +
		"The topology contains protected vendor-derived bytes. Keep it outside kernel\n" +
		"packages and preserve this dedicated, explicitly reviewed redistribution\n" +
		"boundary. This preparation is local-only and performs no remote mutation.\n"
	return []byte(fmt.Sprintf(template, manifest.KernelTag, manifest.KernelABI, manifest.KernelGeneration,
		TopologyName, CardUCMName, HiFiUCMName, MatcherName, ChecksumName, ManifestName,
		manifest.Source.Release, manifest.Source.Revision, manifest.Source.ChecksumManifest.Name,
		manifest.Source.ChecksumManifest.SHA256, sourceLines.String()))
}
