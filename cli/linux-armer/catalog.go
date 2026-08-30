// Package linuxarmer exposes build-time assets shared by the CLI entrypoints.
package linuxarmer

import (
	"embed"
	"io/fs"
)

// embeddedCatalog contains the catalog shipped with this version of the CLI.
//
//go:embed supported-isos.json
var embeddedCatalog embed.FS

// CatalogFS returns the read-only filesystem containing supported-isos.json.
func CatalogFS() fs.FS {
	return embeddedCatalog
}
