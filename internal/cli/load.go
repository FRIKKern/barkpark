package cli

import (
	"fmt"
	"os"
	"sync"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// manifestMemo is the PER-PROCESS floor on /v1/capabilities: one fetch per
// (override path, server, token) for the life of the process, however many
// callers ask.
//
// The on-disk ETag cache (manifest.Fetch → internal/manifest/cache.go, PR
// #14781) already makes a repeat fetch cheap in BYTES — a 304 with no body —
// but it is still a REQUEST, and a request to /v1/capabilities on a struggling
// server is a token lookup queued behind whatever the ledger is seq-scanning
// (task-e2f5ecca0be9a6d1: the auth plugs are where the 500s raise, 218 of them
// in one hour from auth.ex:49 verify_token alone). A round trip we can prove we
// do not need is one we should not make.
//
// It is a memo, not a cache: nothing is written, nothing expires, and the
// process exiting is what invalidates it. That is exactly right for `bp`, whose
// commands are short-lived — and for the two long-lived ones (`bp mcp serve`
// and the board), a manifest that changed mid-session was never being noticed
// anyway, because none of them refetched.
//
// Keyed on the FULL identity, never just the server: a manifest is auth-tier-
// baked (a copy fetched without a token hides every command the caller is
// entitled to — see the hint below), so serving one token's manifest to another
// would be a correctness bug, not an optimisation. Errors are NOT memoised: a
// transient refusal must not poison every later call in the same process.
var manifestMemo sync.Map // memoKey -> *manifest.Manifest

type memoKey struct{ override, server, token string }

// loadManifest acquires the capabilities manifest the CLI dispatches off of,
// at most ONCE per process per identity (manifestMemo, above).
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
	key := memoKey{override: manifestOverridePath(g), server: ctx.Server, token: ctx.Token}
	if hit, ok := manifestMemo.Load(key); ok {
		return hit.(*manifest.Manifest), nil
	}
	m, err := loadManifestUncached(g, ctx)
	if err != nil {
		return nil, err
	}
	manifestMemo.Store(key, m)
	return m, nil
}

// resetManifestMemo drops every memoised manifest. Test-only seam: the memo is
// process-global by design, so a test that exercises the fetch path twice would
// otherwise see the previous test's answer.
func resetManifestMemo() { manifestMemo = sync.Map{} }

// loadManifestUncached is the acquisition itself — the pre-memo loadManifest,
// unchanged. Keeping it a separate function is what makes the memo a countable
// seam: a test can call loadManifest N times against one httptest server and
// assert the server saw exactly one GET.
func loadManifestUncached(g globals, ctx manifest.Context) (*manifest.Manifest, error) {
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
