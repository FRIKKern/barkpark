package setup

import (
	"fmt"
	"strings"
)

// executeCloud drives the Barkpark Cloud target: it logs the user in to Barkpark
// Cloud through the injected CloudLogin hook and either connects bp to the picked
// Barkpark (delegating to the UNCHANGED executeConnect path so the connection is
// probed, remembered, and defaulted exactly like `--target connect`) or finishes
// logged-in when there is no server to connect to.
//
// The setup package never imports cloudclient — the whole cloud device-login /
// fleet-pick flow lives behind opts.CloudLogin, wired by the cli built-in. A nil
// hook (a non-CLI embedding) is a clear error: this target cannot run without it.
func executeCloud(plan SetupPlan, opts Options) error {
	if opts.CloudLogin == nil {
		return errNoCloudLogin()
	}

	if opts.DryRun {
		// A dry run never logs in / talks to the network: it describes the flow.
		// The JSON dry-run is rendered by the caller from BuildPlan; print nothing.
		if !opts.json() {
			w := opts.out()
			fmt.Fprintln(w, "dry-run: would log in to Barkpark Cloud (browser device link), list your Barkparks, and connect bp to the one you pick")
			fmt.Fprintln(w, "  no login, no network call, no write (dry run)")
		}
		return nil
	}

	res, err := opts.CloudLogin(opts)
	if err != nil {
		return err
	}

	// Logged-in-only is a COMPLETE outcome, not a dead end (empty fleet, no admin
	// token and no manual paste, or no selection): being logged in is a valid end
	// state. The hook already printed the actionable guidance; we just record it.
	if res.LoggedInOnly || strings.TrimSpace(res.Server) == "" {
		opts.setResult(Result{
			OK:      true,
			Target:  TargetCloud,
			Message: "logged in to Barkpark Cloud",
		})
		if !opts.json() {
			w := opts.out()
			fmt.Fprintln(w, "✓ logged in to Barkpark Cloud (no server connected — you can connect later with `bp setup`)")
		}
		return nil
	}

	// A Barkpark was picked: delegate to the unchanged connect executor. It probes
	// the server with the resolved admin token, persists via opts.Store, and prints
	// the same premium connect summary — so `bp doc ls` works right after.
	connectPlan := SetupPlan{
		Target: TargetConnect,
		Server: res.Server,
		Token:  res.Token,
		Name:   strings.TrimSpace(res.Name),
	}
	return executeConnect(connectPlan, opts)
}

// buildCloudPlan is the structured dry-run for the cloud target: it describes the
// login → pick → connect flow WITHOUT logging in or touching the network. A nil
// hook is the same clear error executeCloud gives.
func buildCloudPlan(plan SetupPlan, opts Options) (Plan, error) {
	if opts.CloudLogin == nil {
		return Plan{}, errNoCloudLogin()
	}
	p := Plan{
		Target:  TargetCloud,
		DryRun:  true,
		Plugins: planPlugins(nil), // cloud never seeds/whitelists — connect ignores plugins
		Env:     map[string]string{},
	}
	p.addStep("log in to Barkpark Cloud in your browser (device link); the session token is stored 0600", "")
	p.addStep("list your Barkparks and pick one (an empty fleet finishes logged-in with launch guidance)", "")
	p.addStep("connect bp to the picked Barkpark and default here (its admin token is saved as the server token)", "")
	return p, nil
}

// errNoCloudLogin is the shared "no Barkpark Cloud login is wired" error for the
// nil-hook case (a non-CLI embedding of the setup package). It points at the
// connect target as the hook-free escape hatch.
func errNoCloudLogin() error {
	return fmt.Errorf("setup cloud: no Barkpark Cloud login is wired for this build — use `--target connect --server <url>` instead")
}
