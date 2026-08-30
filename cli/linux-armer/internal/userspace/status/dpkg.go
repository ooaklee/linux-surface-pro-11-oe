package status

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
)

// maxDpkgStatusBytes bounds memory and scanner work when reading an untrusted
// mounted target's package database.
const maxDpkgStatusBytes = 32 << 20

// debianPackageName accepts the canonical binary-package tokens that can be
// checked conservatively without interpreting maintainer expressions.
var debianPackageName = regexp.MustCompile(`^[a-z0-9][a-z0-9+.-]*$`)

// debianArchitecture accepts concrete architecture and qualifier tokens while
// leaving wildcard interpretation fail-closed.
var debianArchitecture = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

// debianUpstreamVersion accepts the ASCII vocabulary defined for an upstream
// Debian version while requiring its unambiguous leading digit.
var debianUpstreamVersion = regexp.MustCompile(`^[0-9][A-Za-z0-9.+:~-]*$`)

// debianRevision accepts the narrower ASCII vocabulary defined for a Debian
// package revision.
var debianRevision = regexp.MustCompile(`^[A-Za-z0-9+.~]+$`)

// dependencyAlternativePattern parses the dependency subset retained in a
// binary dpkg status database, including version and architecture constraints.
var dependencyAlternativePattern = regexp.MustCompile(`^([a-z0-9][a-z0-9+.-]*)(?::([a-z0-9-]+))?(?:\s*\(\s*(<<|<=|=|>=|>>)\s*([^)]+?)\s*\))?(?:\s*\[([^]]+)\])?(?:\s*(<[^>]+>(?:\s*<[^>]+>)*)\s*)?$`)

// dpkgPackage contains the status fields needed to determine whether a specific
// package and architecture are installed at the expected version.
type dpkgPackage struct {
	// Name is dpkg's canonical package name.
	Name string
	// Status is the normalised three-word dpkg selection and state tuple.
	Status string
	// Version is the exact Debian package version string.
	Version string
	// Architecture distinguishes entries for multiarch package names.
	Architecture string
	// MultiArch records whether another architecture may satisfy dependencies.
	MultiArch string
	// Depends contains direct runtime relationships declared by the package.
	Depends string
	// PreDepends contains relationships that must be satisfied before unpacking.
	PreDepends string
	// Provides names virtual packages that this package can satisfy.
	Provides string
}

// dependencyHealth separates definite missing relationships from constraints
// that cannot be proven from static dpkg status.
type dependencyHealth struct {
	missing       []string
	indeterminate []string
}

// dependencyAlternative is one safely parsed alternative in a dependency group.
type dependencyAlternative struct {
	name             string
	qualifier        string
	operator         string
	version          string
	architectureList string
	profiles         string
}

// dependencyOutcome distinguishes proof of satisfaction, definite absence,
// conditional non-applicability, and constraints that remain indeterminate.
type dependencyOutcome uint8

// Dependency outcomes drive fail-closed group evaluation without executing a
// package manager or target binary.
const (
	dependencyUnsatisfied dependencyOutcome = iota
	dependencySatisfied
	dependencyNotApplicable
	dependencyIndeterminate
)

// installed reports whether dpkg considers the package fully installed.
func (p dpkgPackage) installed() bool {
	fields := strings.Fields(p.Status)
	return len(fields) == 3 && (fields[0] == "install" || fields[0] == "hold") && fields[1] == "ok" && fields[2] == "installed"
}

// dpkgDatabase is a read-only index of parsed package status records; present
// distinguishes a missing database from a valid database with no matching items.
type dpkgDatabase struct {
	present  bool
	packages map[string][]dpkgPackage
}

// loadDpkgDatabase safely reads and parses the target root's dpkg status file,
// treating its absence as an unavailable database rather than a fatal error.
func loadDpkgDatabase(fs *rootedFS) (dpkgDatabase, error) {
	path, info, err := fs.regular("var/lib/dpkg/status", false)
	if missing(err) {
		return dpkgDatabase{packages: make(map[string][]dpkgPackage)}, nil
	}
	if err != nil {
		return dpkgDatabase{}, fmt.Errorf("inspect dpkg status: %w", err)
	}
	if info.Size() > maxDpkgStatusBytes {
		return dpkgDatabase{}, fmt.Errorf("dpkg status exceeds %d bytes", maxDpkgStatusBytes)
	}
	file, err := os.Open(path)
	if err != nil {
		return dpkgDatabase{}, fmt.Errorf("open dpkg status: %w", err)
	}
	defer file.Close()
	packages, err := parseDpkgStatus(io.LimitReader(file, maxDpkgStatusBytes+1))
	if err != nil {
		return dpkgDatabase{}, fmt.Errorf("parse dpkg status: %w", err)
	}
	return dpkgDatabase{present: true, packages: packages}, nil
}

// parseDpkgStatus parses Debian control-file records with bounded scanner memory
// and retains only the fields used by static inspection.
func parseDpkgStatus(reader io.Reader) (map[string][]dpkgPackage, error) {
	packages := make(map[string][]dpkgPackage)
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), maxDpkgStatusBytes+1)
	record := make(map[string]string)
	lastField := ""
	flush := func() error {
		if len(record) == 0 {
			return nil
		}
		name := strings.TrimSpace(record["Package"])
		if name == "" {
			return errors.New("record has no Package field")
		}
		pkg := dpkgPackage{
			Name:         name,
			Status:       strings.TrimSpace(record["Status"]),
			Version:      strings.TrimSpace(record["Version"]),
			Architecture: strings.TrimSpace(record["Architecture"]),
			MultiArch:    strings.TrimSpace(record["Multi-Arch"]),
			Depends:      strings.TrimSpace(record["Depends"]),
			PreDepends:   strings.TrimSpace(record["Pre-Depends"]),
			Provides:     strings.TrimSpace(record["Provides"]),
		}
		packages[name] = append(packages[name], pkg)
		record = make(map[string]string)
		lastField = ""
		return nil
	}

	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			if err := flush(); err != nil {
				return nil, err
			}
			continue
		}
		if line[0] == ' ' || line[0] == '\t' {
			if lastField == "" {
				return nil, errors.New("continuation line has no field")
			}
			record[lastField] += "\n" + strings.TrimSpace(line)
			continue
		}
		field, value, found := strings.Cut(line, ":")
		if !found || strings.TrimSpace(field) == "" {
			return nil, fmt.Errorf("invalid field line %q", line)
		}
		lastField = strings.TrimSpace(field)
		record[lastField] = strings.TrimSpace(value)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if err := flush(); err != nil {
		return nil, err
	}
	return packages, nil
}

// installed returns the first fully installed package matching name and, when
// supplied, the requested architecture.
func (db dpkgDatabase) installed(name, architecture string) (dpkgPackage, bool) {
	for _, pkg := range db.packages[name] {
		if pkg.installed() && (architecture == "" || pkg.Architecture == architecture) {
			return pkg, true
		}
	}
	return dpkgPackage{}, false
}

// matching returns every package record with the requested name and, when
// supplied, architecture so callers can distinguish absence from broken state.
func (db dpkgDatabase) matching(name, architecture string) []dpkgPackage {
	matching := make([]dpkgPackage, 0)
	for _, pkg := range db.packages[name] {
		if architecture == "" || pkg.Architecture == architecture {
			matching = append(matching, pkg)
		}
	}
	return matching
}

// dependencyHealth evaluates every direct dependency group for a package using
// target architecture and Debian version semantics, failing closed on syntax or
// policy that cannot be proven from dpkg status.
func (db dpkgDatabase) dependencyHealth(pkg dpkgPackage, targetArchitecture string) dependencyHealth {
	health := dependencyHealth{}
	relations := strings.Trim(strings.Join([]string{pkg.PreDepends, pkg.Depends}, ","), " ,\t\r\n")
	if relations == "" {
		return health
	}
	for _, rawGroup := range strings.Split(relations, ",") {
		group := strings.TrimSpace(rawGroup)
		if group == "" {
			continue
		}
		groupSatisfied := false
		groupApplicable := false
		groupIndeterminate := false
		parsedAny := false
		for _, rawAlternative := range strings.Split(group, "|") {
			alternative, parsed := parseDependencyAlternative(rawAlternative)
			if !parsed {
				groupIndeterminate = true
				continue
			}
			parsedAny = true
			outcome := db.evaluateDependencyAlternative(alternative, targetArchitecture)
			if outcome == dependencySatisfied {
				groupSatisfied = true
				break
			}
			switch outcome {
			case dependencyUnsatisfied:
				groupApplicable = true
			case dependencyIndeterminate:
				groupIndeterminate = true
			}
		}
		if !parsedAny {
			groupIndeterminate = true
		}
		if groupSatisfied || (!groupApplicable && !groupIndeterminate) {
			continue
		}
		if groupIndeterminate {
			health.indeterminate = append(health.indeterminate, group)
		} else {
			health.missing = append(health.missing, group)
		}
	}
	health.missing = uniqueSortedStrings(health.missing)
	health.indeterminate = uniqueSortedStrings(health.indeterminate)
	return health
}

// parseDependencyAlternative parses one binary-package relationship without
// expanding variables, build profiles, or wildcard architecture expressions.
func parseDependencyAlternative(raw string) (dependencyAlternative, bool) {
	match := dependencyAlternativePattern.FindStringSubmatch(strings.TrimSpace(raw))
	if len(match) != 7 {
		return dependencyAlternative{}, false
	}
	return dependencyAlternative{
		name:             match[1],
		qualifier:        match[2],
		operator:         match[3],
		version:          strings.TrimSpace(match[4]),
		architectureList: strings.TrimSpace(match[5]),
		profiles:         strings.TrimSpace(match[6]),
	}, true
}

// evaluateDependencyAlternative proves whether one parsed relationship is
// satisfied, absent, inapplicable, or indeterminate for the target architecture.
func (db dpkgDatabase) evaluateDependencyAlternative(alternative dependencyAlternative, targetArchitecture string) dependencyOutcome {
	if alternative.profiles != "" {
		return dependencyIndeterminate
	}
	applies, certain := dependencyAppliesToArchitecture(alternative.architectureList, targetArchitecture)
	if !certain {
		return dependencyIndeterminate
	}
	if !applies {
		return dependencyNotApplicable
	}
	outcome := dependencyUnsatisfied
	for _, candidate := range db.packages[alternative.name] {
		candidateOutcome := packageSatisfiesAlternative(candidate, alternative, targetArchitecture)
		if candidateOutcome == dependencySatisfied {
			return dependencySatisfied
		}
		if candidateOutcome == dependencyIndeterminate {
			outcome = dependencyIndeterminate
		}
	}
	for _, packages := range db.packages {
		for _, provider := range packages {
			providerOutcome := providerSatisfiesAlternative(provider, alternative, targetArchitecture)
			if providerOutcome == dependencySatisfied {
				return dependencySatisfied
			}
			if providerOutcome == dependencyIndeterminate {
				outcome = dependencyIndeterminate
			}
		}
	}
	return outcome
}

// dependencyAppliesToArchitecture evaluates simple positive or negative Debian
// architecture restrictions and reports wildcard expressions as indeterminate.
func dependencyAppliesToArchitecture(expression, targetArchitecture string) (bool, bool) {
	if expression == "" {
		return true, true
	}
	if !debianArchitecture.MatchString(targetArchitecture) {
		return false, false
	}
	positive := false
	negative := false
	positiveMatch := false
	negativeMatch := false
	for _, token := range strings.Fields(expression) {
		negated := strings.HasPrefix(token, "!")
		architecture := strings.TrimPrefix(token, "!")
		if !debianArchitecture.MatchString(architecture) || strings.Contains(architecture, "any") {
			return false, false
		}
		if negated {
			negative = true
			negativeMatch = negativeMatch || architecture == targetArchitecture
		} else {
			positive = true
			positiveMatch = positiveMatch || architecture == targetArchitecture
		}
	}
	if positive && negative {
		return false, false
	}
	if positive {
		return positiveMatch, true
	}
	return !negativeMatch, negative
}

// packageSatisfiesAlternative checks installed state, multiarch semantics, and
// an optional Debian version constraint for one real package record.
func packageSatisfiesAlternative(pkg dpkgPackage, alternative dependencyAlternative, targetArchitecture string) dependencyOutcome {
	if !pkg.installed() {
		return dependencyUnsatisfied
	}
	architectureOutcome := packageArchitectureOutcome(pkg, alternative.qualifier, targetArchitecture)
	if architectureOutcome != dependencySatisfied {
		return architectureOutcome
	}
	return versionOutcome(pkg.Version, alternative.operator, alternative.version)
}

// packageArchitectureOutcome proves whether a package record can satisfy the
// dependency's native, exact, or :any architecture qualifier.
func packageArchitectureOutcome(pkg dpkgPackage, qualifier, targetArchitecture string) dependencyOutcome {
	if !debianArchitecture.MatchString(pkg.Architecture) || !debianArchitecture.MatchString(targetArchitecture) {
		return dependencyIndeterminate
	}
	switch qualifier {
	case "", "native":
		if pkg.Architecture == targetArchitecture || pkg.Architecture == "all" || pkg.MultiArch == "foreign" {
			return dependencySatisfied
		}
		return dependencyUnsatisfied
	case "any":
		if pkg.MultiArch == "allowed" || pkg.MultiArch == "foreign" {
			return dependencySatisfied
		}
		return dependencyIndeterminate
	default:
		if !debianArchitecture.MatchString(qualifier) {
			return dependencyIndeterminate
		}
		if pkg.Architecture == qualifier || pkg.Architecture == "all" {
			return dependencySatisfied
		}
		return dependencyUnsatisfied
	}
}

// providerSatisfiesAlternative checks a fully installed package's versioned
// Provides relationships when no real package record proves satisfaction.
func providerSatisfiesAlternative(provider dpkgPackage, alternative dependencyAlternative, targetArchitecture string) dependencyOutcome {
	if !provider.installed() || strings.TrimSpace(provider.Provides) == "" {
		return dependencyUnsatisfied
	}
	architectureOutcome := packageArchitectureOutcome(provider, alternative.qualifier, targetArchitecture)
	if architectureOutcome != dependencySatisfied {
		return architectureOutcome
	}
	outcome := dependencyUnsatisfied
	for _, rawProvided := range strings.Split(provider.Provides, ",") {
		provided, parsed := parseDependencyAlternative(rawProvided)
		if !parsed {
			outcome = dependencyIndeterminate
			continue
		}
		if provided.name != alternative.name {
			continue
		}
		if alternative.operator == "" {
			return dependencySatisfied
		}
		if provided.operator != "=" || provided.version == "" {
			return dependencyIndeterminate
		}
		return versionOutcome(provided.version, alternative.operator, alternative.version)
	}
	return outcome
}

// versionOutcome compares a candidate version with one Debian relationship.
func versionOutcome(candidateVersion, operator, requiredVersion string) dependencyOutcome {
	if operator == "" {
		return dependencySatisfied
	}
	if strings.TrimSpace(candidateVersion) == "" || strings.TrimSpace(requiredVersion) == "" {
		return dependencyIndeterminate
	}
	comparison, err := compareDebianVersions(candidateVersion, requiredVersion)
	if err != nil {
		return dependencyIndeterminate
	}
	satisfied := false
	switch operator {
	case "<<":
		satisfied = comparison < 0
	case "<=":
		satisfied = comparison <= 0
	case "=":
		satisfied = comparison == 0
	case ">=":
		satisfied = comparison >= 0
	case ">>":
		satisfied = comparison > 0
	default:
		return dependencyIndeterminate
	}
	if satisfied {
		return dependencySatisfied
	}
	return dependencyUnsatisfied
}

// compareDebianVersions implements dpkg's epoch, upstream, and revision order
// without invoking any executable from the host or target root.
func compareDebianVersions(left, right string) (int, error) {
	leftEpoch, leftUpstream, leftRevision, err := splitDebianVersion(left)
	if err != nil {
		return 0, err
	}
	rightEpoch, rightUpstream, rightRevision, err := splitDebianVersion(right)
	if err != nil {
		return 0, err
	}
	if comparison := compareNumericStrings(leftEpoch, rightEpoch); comparison != 0 {
		return comparison, nil
	}
	if comparison := compareDebianVersionPart(leftUpstream, rightUpstream); comparison != 0 {
		return comparison, nil
	}
	return compareDebianVersionPart(leftRevision, rightRevision), nil
}

// splitDebianVersion validates and separates epoch, upstream version, and
// Debian revision, treating an absent epoch or revision as zero.
func splitDebianVersion(version string) (epoch, upstream, revision string, err error) {
	version = strings.TrimSpace(version)
	if version == "" || strings.ContainsAny(version, "\x00\r\n\t ") {
		return "", "", "", fmt.Errorf("invalid Debian version %q", version)
	}
	epoch = "0"
	remainder := version
	if candidateEpoch, rest, found := strings.Cut(version, ":"); found {
		if candidateEpoch == "" || strings.Trim(candidateEpoch, "0123456789") != "" {
			return "", "", "", fmt.Errorf("invalid Debian version epoch %q", candidateEpoch)
		}
		epoch = candidateEpoch
		remainder = rest
	}
	if remainder == "" {
		return "", "", "", fmt.Errorf("Debian version %q has no upstream part", version)
	}
	upstream = remainder
	revision = "0"
	if separator := strings.LastIndexByte(remainder, '-'); separator >= 0 {
		upstream = remainder[:separator]
		revision = remainder[separator+1:]
		if upstream == "" || revision == "" {
			return "", "", "", fmt.Errorf("invalid Debian version %q", version)
		}
	}
	if !debianUpstreamVersion.MatchString(upstream) || !debianRevision.MatchString(revision) {
		return "", "", "", fmt.Errorf("invalid Debian version %q", version)
	}
	return epoch, upstream, revision, nil
}

// compareNumericStrings compares non-negative decimal strings without integer
// overflow by normalising leading zeroes first.
func compareNumericStrings(left, right string) int {
	left = strings.TrimLeft(left, "0")
	right = strings.TrimLeft(right, "0")
	if left == "" {
		left = "0"
	}
	if right == "" {
		right = "0"
	}
	if len(left) < len(right) {
		return -1
	}
	if len(left) > len(right) {
		return 1
	}
	return strings.Compare(left, right)
}

// compareDebianVersionPart applies dpkg's alternating non-digit and digit-run
// ordering, including the special precedence of a tilde.
func compareDebianVersionPart(left, right string) int {
	for leftIndex, rightIndex := 0, 0; leftIndex < len(left) || rightIndex < len(right); {
		for (leftIndex < len(left) && !isASCIIDigit(left[leftIndex])) || (rightIndex < len(right) && !isASCIIDigit(right[rightIndex])) {
			leftOrder := 0
			if leftIndex < len(left) && !isASCIIDigit(left[leftIndex]) {
				leftOrder = debianCharacterOrder(left[leftIndex])
				leftIndex++
			}
			rightOrder := 0
			if rightIndex < len(right) && !isASCIIDigit(right[rightIndex]) {
				rightOrder = debianCharacterOrder(right[rightIndex])
				rightIndex++
			}
			if leftOrder < rightOrder {
				return -1
			}
			if leftOrder > rightOrder {
				return 1
			}
		}
		leftStart := leftIndex
		for leftStart < len(left) && left[leftStart] == '0' {
			leftStart++
		}
		leftEnd := leftStart
		for leftEnd < len(left) && isASCIIDigit(left[leftEnd]) {
			leftEnd++
		}
		rightStart := rightIndex
		for rightStart < len(right) && right[rightStart] == '0' {
			rightStart++
		}
		rightEnd := rightStart
		for rightEnd < len(right) && isASCIIDigit(right[rightEnd]) {
			rightEnd++
		}
		if leftEnd-leftStart < rightEnd-rightStart {
			return -1
		}
		if leftEnd-leftStart > rightEnd-rightStart {
			return 1
		}
		if comparison := strings.Compare(left[leftStart:leftEnd], right[rightStart:rightEnd]); comparison != 0 {
			return comparison
		}
		leftIndex = leftEnd
		rightIndex = rightEnd
	}
	return 0
}

// debianCharacterOrder implements dpkg ordering for non-digit version bytes.
func debianCharacterOrder(character byte) int {
	if character == '~' {
		return -1
	}
	if (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') {
		return int(character)
	}
	return int(character) + 256
}

// isASCIIDigit reports whether one Debian version byte is a decimal digit.
func isASCIIDigit(character byte) bool {
	return character >= '0' && character <= '9'
}
