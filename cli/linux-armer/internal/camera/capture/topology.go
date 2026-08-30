package capture

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// topology parsing expressions accept the stable media-ctl entity, pad,
// device-node, format, and outgoing-link lines while ignoring extra fields.
var (
	entityLinePattern = regexp.MustCompile(`^- entity [0-9]+: (.+?)(?: \([^)]*\))?$`)
	padLinePattern    = regexp.MustCompile(`^\s*pad([0-9]+):\s*(Source|Sink)\b`)
	deviceLinePattern = regexp.MustCompile(`^\s*device node name\s+(\S+)\s*$`)
	formatLinePattern = regexp.MustCompile(`fmt:([^/\s\]]+)/([0-9]+)x([0-9]+)`)
	linkLinePattern   = regexp.MustCompile(`->\s+"([^"]+)":([0-9]+)\s+\[([^]]+)\]`)
)

// mediaTopology is the parsed subset of one bounded media-controller report.
type mediaTopology struct {
	// entities maps exact entity names to their parsed records.
	entities map[string]*mediaEntity
	// order retains deterministic entity declaration order.
	order []string
}

// mediaEntity records one entity's node, pads, formats, and outgoing links.
type mediaEntity struct {
	// name is the exact entity name printed by media-ctl.
	name string
	// device is the optional device node owned by this entity.
	device string
	// pads maps pad numbers to their parsed records.
	pads map[int]*mediaPad
}

// mediaPad records the small subset needed to prove the camera route.
type mediaPad struct {
	// number is the entity-local pad number.
	number int
	// direction is either Source or Sink.
	direction string
	// format is the negotiated media-bus code, when reported.
	format string
	// width is the negotiated pad width.
	width int
	// height is the negotiated pad height.
	height int
	// links contains outgoing links declared beneath this pad.
	links []mediaLink
}

// mediaLink identifies one enabled or disabled outgoing entity connection.
type mediaLink struct {
	// targetEntity is the exact target entity name.
	targetEntity string
	// targetPad is the target's entity-local pad number.
	targetPad int
	// flags are the normalised media-ctl link flags.
	flags string
}

// parseTopology parses one media-ctl report and rejects duplicate entities,
// malformed recognised lines, and links without a source pad.
func parseTopology(content string) (mediaTopology, error) {
	topology := mediaTopology{entities: make(map[string]*mediaEntity)}
	var currentEntity *mediaEntity
	var currentPad *mediaPad
	for lineNumber, line := range strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n") {
		if match := entityLinePattern.FindStringSubmatch(line); match != nil {
			name := strings.TrimSpace(match[1])
			if name == "" {
				return mediaTopology{}, fmt.Errorf("media topology line %d has an empty entity", lineNumber+1)
			}
			if _, exists := topology.entities[name]; exists {
				return mediaTopology{}, fmt.Errorf("media topology repeats entity %q", name)
			}
			currentEntity = &mediaEntity{name: name, pads: make(map[int]*mediaPad)}
			topology.entities[name] = currentEntity
			topology.order = append(topology.order, name)
			currentPad = nil
			continue
		}
		if currentEntity == nil {
			continue
		}
		if match := deviceLinePattern.FindStringSubmatch(line); match != nil {
			if currentEntity.device != "" && currentEntity.device != match[1] {
				return mediaTopology{}, fmt.Errorf("media entity %q reports more than one device node", currentEntity.name)
			}
			currentEntity.device = match[1]
			continue
		}
		if match := padLinePattern.FindStringSubmatch(line); match != nil {
			number, err := strconv.Atoi(match[1])
			if err != nil || number < 0 || number > 255 {
				return mediaTopology{}, fmt.Errorf("media topology line %d has an invalid pad", lineNumber+1)
			}
			if _, exists := currentEntity.pads[number]; exists {
				return mediaTopology{}, fmt.Errorf("media entity %q repeats pad %d", currentEntity.name, number)
			}
			currentPad = &mediaPad{number: number, direction: match[2]}
			currentEntity.pads[number] = currentPad
			continue
		}
		if match := formatLinePattern.FindStringSubmatch(line); match != nil {
			if currentPad == nil {
				return mediaTopology{}, fmt.Errorf("media topology line %d reports a format without a pad", lineNumber+1)
			}
			width, widthErr := strconv.Atoi(match[2])
			height, heightErr := strconv.Atoi(match[3])
			if widthErr != nil || heightErr != nil || width < 1 || height < 1 {
				return mediaTopology{}, fmt.Errorf("media topology line %d has invalid dimensions", lineNumber+1)
			}
			currentPad.format, currentPad.width, currentPad.height = match[1], width, height
		}
		if match := linkLinePattern.FindStringSubmatch(line); match != nil {
			if currentPad == nil || currentPad.direction != "Source" {
				return mediaTopology{}, fmt.Errorf("media topology line %d reports an outgoing link without a source pad", lineNumber+1)
			}
			targetPad, err := strconv.Atoi(match[2])
			if err != nil || targetPad < 0 || targetPad > 255 {
				return mediaTopology{}, fmt.Errorf("media topology line %d has an invalid target pad", lineNumber+1)
			}
			currentPad.links = append(currentPad.links, mediaLink{
				targetEntity: match[1], targetPad: targetPad,
				flags: strings.ToUpper(strings.ReplaceAll(match[3], " ", "")),
			})
		}
	}
	if len(topology.entities) == 0 {
		return mediaTopology{}, fmt.Errorf("media topology contains no entities")
	}
	return topology, nil
}

// discoverPipeline extracts the one exact IMX681 to CSIPHY2 to CSID0 to VFE
// route from a parsed topology and rejects ambiguity.
func discoverPipeline(mediaDevice string, topology mediaTopology) (Pipeline, error) {
	for _, required := range []string{phyEntity, csidEntity, vfeEntity} {
		if _, exists := topology.entities[required]; !exists {
			return Pipeline{}, fmt.Errorf("required media entity %q is absent", required)
		}
	}
	type sensorRoute struct {
		// entity is one IMX681 entity connected to the compiled PHY.
		entity *mediaEntity
		// pad is that entity's unique connected source pad.
		pad *mediaPad
	}
	var sensors []sensorRoute
	for _, name := range topology.order {
		entity := topology.entities[name]
		if !strings.Contains(strings.ToLower(entity.name), "imx681") {
			continue
		}
		for _, pad := range sortedPads(entity) {
			if pad.direction != "Source" {
				continue
			}
			for _, link := range pad.links {
				if link.targetEntity == phyEntity && link.targetPad == 0 && linkEnabled(link) {
					sensors = append(sensors, sensorRoute{entity: entity, pad: pad})
				}
			}
		}
	}
	if len(sensors) != 1 {
		return Pipeline{}, fmt.Errorf("expected one enabled IMX681 link to %s:0, found %d", phyEntity, len(sensors))
	}
	pixelFormat, order, err := formatMapping(sensors[0].pad.format)
	if err != nil {
		return Pipeline{}, err
	}
	vfePad := topology.entities[vfeEntity].pads[1]
	if vfePad == nil || vfePad.direction != "Source" {
		return Pipeline{}, fmt.Errorf("required %s source pad 1 is absent", vfeEntity)
	}
	var targets []mediaLink
	for _, link := range vfePad.links {
		if linkEnabled(link) {
			targets = append(targets, link)
		}
	}
	if len(targets) != 1 {
		return Pipeline{}, fmt.Errorf("expected one enabled capture link from %s:1, found %d", vfeEntity, len(targets))
	}
	videoEntity := topology.entities[targets[0].targetEntity]
	if videoEntity == nil || !strings.HasPrefix(videoEntity.device, "/dev/video") {
		return Pipeline{}, fmt.Errorf("the VFE capture target does not own a /dev/video node")
	}
	pipeline := Pipeline{
		MediaDevice: mediaDevice, VideoDevice: videoEntity.device,
		SensorEntity: sensors[0].entity.name, SensorSourcePad: sensors[0].pad.number,
		SensorControlDevice: sensors[0].entity.device, VideoEntity: videoEntity.name,
		MediaBusFormat: sensors[0].pad.format, PixelFormat: pixelFormat, BayerOrder: order,
	}
	for _, link := range []struct {
		// source is the exact route entity owning the outgoing pad.
		source string
		// sourcePad is the exact outgoing pad number.
		sourcePad int
		// target is the exact next entity in the route.
		target string
		// targetPad is the exact incoming pad number.
		targetPad int
		// enabled requires the link to be active before configuration.
		enabled bool
	}{
		{pipeline.SensorEntity, pipeline.SensorSourcePad, phyEntity, 0, true},
		{phyEntity, 1, csidEntity, 0, false},
		{csidEntity, 1, vfeEntity, 0, false},
		{vfeEntity, 1, pipeline.VideoEntity, 0, true},
	} {
		if err := requireRouteLink(topology, link.source, link.sourcePad, link.target, link.targetPad, link.enabled); err != nil {
			return Pipeline{}, err
		}
	}
	return pipeline, nil
}

// requireRouteLink proves that one declared source-to-sink connection exists
// and that no different link from the source pad is active. Callers may also
// require the selected link to be enabled after graph configuration.
func requireRouteLink(topology mediaTopology, source string, sourcePad int, target string, targetPad int, requireEnabled bool) error {
	sourceEntity := topology.entities[source]
	targetEntity := topology.entities[target]
	if sourceEntity == nil || sourceEntity.pads[sourcePad] == nil || sourceEntity.pads[sourcePad].direction != "Source" {
		return fmt.Errorf("camera route source pad %q:%d is absent", source, sourcePad)
	}
	if targetEntity == nil || targetEntity.pads[targetPad] == nil || targetEntity.pads[targetPad].direction != "Sink" {
		return fmt.Errorf("camera route target pad %q:%d is absent", target, targetPad)
	}
	matching := 0
	matchingEnabled := false
	for _, link := range sourceEntity.pads[sourcePad].links {
		if linkEnabled(link) && (link.targetEntity != target || link.targetPad != targetPad) {
			return fmt.Errorf("camera route source pad %q:%d has an unexpected enabled target", source, sourcePad)
		}
		if link.targetEntity == target && link.targetPad == targetPad {
			matching++
			matchingEnabled = matchingEnabled || linkEnabled(link)
		}
	}
	if matching != 1 {
		return fmt.Errorf("camera route requires one declared link from %q:%d to %q:%d; found %d", source, sourcePad, target, targetPad, matching)
	}
	if requireEnabled && !matchingEnabled {
		return fmt.Errorf("camera route link from %q:%d to %q:%d is not enabled", source, sourcePad, target, targetPad)
	}
	return nil
}

// sortedPads returns one entity's pads in stable numeric order.
func sortedPads(entity *mediaEntity) []*mediaPad {
	numbers := make([]int, 0, len(entity.pads))
	for number := range entity.pads {
		numbers = append(numbers, number)
	}
	sort.Ints(numbers)
	pads := make([]*mediaPad, 0, len(numbers))
	for _, number := range numbers {
		pads = append(pads, entity.pads[number])
	}
	return pads
}

// linkEnabled reports whether media-ctl marks a link as enabled.
func linkEnabled(link mediaLink) bool {
	for _, flag := range strings.Split(link.flags, ",") {
		if flag == "ENABLED" {
			return true
		}
	}
	return false
}

// formatMapping maps the four supported ten-bit media-bus orders to their
// matching packed V4L2 fourcc and explicit Bayer order.
func formatMapping(mediaBusFormat string) (string, BayerOrder, error) {
	switch mediaBusFormat {
	case "SBGGR10_1X10":
		return "pBAA", BayerBGGR, nil
	case "SGBRG10_1X10":
		return "pGAA", BayerGBRG, nil
	case "SGRBG10_1X10":
		return "pgAA", BayerGRBG, nil
	case "SRGGB10_1X10":
		return "pRAA", BayerRGGB, nil
	default:
		return "", "", fmt.Errorf("unsupported IMX681 media-bus format %q", mediaBusFormat)
	}
}

// validateConfiguredTopology proves every pad retained the exact compiled
// format and dimensions after configuration.
func validateConfiguredTopology(topology mediaTopology, pipeline Pipeline) error {
	type requiredPad struct {
		// entity is the exact entity name to inspect.
		entity string
		// pad is the exact entity-local pad number.
		pad int
		// width is the required negotiated width.
		width int
	}
	required := []requiredPad{
		{pipeline.SensorEntity, pipeline.SensorSourcePad, sensorWidth},
		{phyEntity, 0, sensorWidth}, {phyEntity, 1, sensorWidth},
		{csidEntity, 0, sensorWidth}, {csidEntity, 1, Width},
		{vfeEntity, 0, Width}, {vfeEntity, 1, Width},
	}
	for _, check := range required {
		entity := topology.entities[check.entity]
		if entity == nil || entity.pads[check.pad] == nil {
			return fmt.Errorf("configured media pad %q:%d is absent", check.entity, check.pad)
		}
		pad := entity.pads[check.pad]
		if pad.format != pipeline.MediaBusFormat || pad.width != check.width || pad.height != Height {
			return fmt.Errorf("configured media pad %q:%d is %s/%dx%d, expected %s/%dx%d",
				check.entity, check.pad, pad.format, pad.width, pad.height,
				pipeline.MediaBusFormat, check.width, Height)
		}
	}
	for _, link := range []struct {
		// source is the exact route entity owning the outgoing pad.
		source string
		// sourcePad is the exact outgoing pad number.
		sourcePad int
		// target is the exact next entity in the route.
		target string
		// targetPad is the exact incoming pad number.
		targetPad int
	}{
		{pipeline.SensorEntity, pipeline.SensorSourcePad, phyEntity, 0},
		{phyEntity, 1, csidEntity, 0},
		{csidEntity, 1, vfeEntity, 0},
		{vfeEntity, 1, pipeline.VideoEntity, 0},
	} {
		if err := requireRouteLink(topology, link.source, link.sourcePad, link.target, link.targetPad, true); err != nil {
			return err
		}
	}
	return nil
}
