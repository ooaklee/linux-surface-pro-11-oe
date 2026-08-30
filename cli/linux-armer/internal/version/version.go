// Package version contains build metadata populated by release linker flags.
package version

import "runtime/debug"

var (
	// Version is the semantic release version injected at link time.
	Version = "dev"
	// Commit is the source revision injected at link time.
	Commit = "unknown"
	// Date is the build timestamp injected at link time.
	Date = "unknown"
)

// Info returns build metadata, using Go module metadata for local builds when
// linker-provided values are unavailable.
func Info() (version, commit, date string) {
	version, commit, date = Version, Commit, Date
	if info, ok := debug.ReadBuildInfo(); ok {
		if version == "dev" && info.Main.Version != "" && info.Main.Version != "(devel)" {
			version = info.Main.Version
		}
		for _, setting := range info.Settings {
			switch setting.Key {
			case "vcs.revision":
				if commit == "unknown" {
					commit = setting.Value
				}
			case "vcs.time":
				if date == "unknown" {
					date = setting.Value
				}
			}
		}
	}
	return version, commit, date
}
