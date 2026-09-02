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

	// First run (no config, no BARKPARK_* env) with no explicit -s flag: refuse
	// to silently fall through to the baked localhost default — even one that
	// happens to answer — so a fresh install always lands on `bp setup` instead
	// of whatever dev server is listening on this machine. Never prompts.
	if FirstRun() && g.server == "" {
		return nil, fmt.Errorf("no server configured.\n  run `bp setup` to connect to a server or bring one up,\n  or pass -s <url> / set BARKPARK_API_URL for a one-off call")
	}

	client := apiclient.New(apiclient.Config{
		BaseURL: ctx.Server,
		Token:   ctx.Token,
	})
	cache := manifest.NewCache("")
	m, err := manifest.Fetch(client, cache)
	if err != nil {
		// First run (no config, no BARKPARK_* env): the failure is almost always
		// "nothing is configured yet", so point at bp setup instead of the
		// manifest plumbing. Exit class stays 1 (network); never prompts.
		if FirstRun() {
			return nil, fmt.Errorf("no server configured and %s is not answering.\n  run `bp setup` to connect to a server or bring one up,\n  or pass -s <url> / set BARKPARK_API_URL for a one-off call", ctx.Server)
		}
		// THE HINT NAMES THE CREDENTIAL ON PURPOSE (task-154120e78138085a).
		// The manifest is auth-tier-baked: a copy fetched without a token
		// carries auth_tier "none" and HIDES every command the caller is
		// entitled to, so an operator who follows the old hint by curling the
		// URL gets a bp that reports `task` does not exist — a permanent,
		// misdiagnosed failure traded for a transient one. The file override is
		// for running before /v1/capabilities is deployed; it is NOT a
		// workaround for a refusal, which is what the on-disk cache is for.
		return nil, fmt.Errorf("acquire manifest from %s%s: %w (hint: to run before /v1/capabilities is deployed, set BARKPARK_MANIFEST=<file> or pass --manifest <file> — the file must have been fetched WITH your credential, since a manifest fetched anonymously carries auth_tier \"none\" and hides every command you are entitled to)",
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
