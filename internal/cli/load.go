package cli

import (
	"fmt"
	"os"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// loadManifest acquires the capabilities manifest the CLI dispatches off of.
//
// Precedence:
//  1. --manifest <path> flag, if given.
//  2. $BARKPARK_MANIFEST env var, if set.
//  3. The on-disk ETag cache; on miss, GET <server>/v1/capabilities.
//
// The file override is the offline/pre-deploy seam: /v1/capabilities is not live
// on every server yet, so a committed fixture (or any local manifest JSON) lets
// the CLI run end-to-end against an API that only has the data endpoints.
func loadManifest(g globals, ctx manifest.Context) (*manifest.Manifest, error) {
	if path := manifestOverridePath(g); path != "" {
		return loadManifestFile(path)
	}

	client := apiclient.New(apiclient.Config{
		BaseURL: ctx.Server,
		Token:   ctx.Token,
	})
	cache := manifest.NewCache("")
	m, err := manifest.Fetch(client, cache)
	if err != nil {
		return nil, fmt.Errorf("acquire manifest from %s%s: %w (hint: set BARKPARK_MANIFEST=<file> or pass --manifest <file> to run before /v1/capabilities is deployed)",
			ctx.Server, manifest.CapabilitiesPath, err)
	}
	return m, nil
}

// manifestOverridePath returns the --manifest flag value, falling back to the
// BARKPARK_MANIFEST env var. Empty means "no override; go to the network".
func manifestOverridePath(g globals) string {
	if g.manifestPath != "" {
		return g.manifestPath
	}
	return os.Getenv("BARKPARK_MANIFEST")
}

func loadManifestFile(path string) (*manifest.Manifest, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read manifest file %s: %w", path, err)
	}
	m, err := manifest.Parse(body)
	if err != nil {
		return nil, fmt.Errorf("parse manifest file %s: %w", path, err)
	}
	return m, nil
}
