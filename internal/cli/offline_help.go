package cli

import (
	_ "embed"
	"sync"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// offlineHelpManifestJSON is the admin view of the nouns an operator needs
// before the server is up, so `bp org --help` and `bp org oidc-create --help`
// work with no config and no network. The server writes it:
// `cd api && mix barkpark.offline_help`. An ExUnit test fails when the
// committed file differs from the server's command definitions.
//
//go:embed offline_help_manifest.json
var offlineHelpManifestJSON []byte

var (
	offlineHelpOnce sync.Once
	offlineHelp     *manifest.Manifest
)

// offlineHelpManifest returns the embedded help manifest when it covers noun,
// else nil. It is used only to render help after the live manifest failed to
// load; it never dispatches a command.
func offlineHelpManifest(noun string) *manifest.Manifest {
	offlineHelpOnce.Do(func() {
		m, err := manifest.Parse(offlineHelpManifestJSON)
		if err == nil {
			offlineHelp = m
		}
	})
	if offlineHelp == nil || noun == "" {
		return nil
	}
	if _, ok := lookupNoun(offlineHelp.Tree(), noun); !ok {
		return nil
	}
	return offlineHelp
}
