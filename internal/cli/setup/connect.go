package setup

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// capabilitiesProbe is the subset of GET /v1/capabilities the connect executor
// reads: the server identity and the caller's resolved auth tier (the manifest
// echoes the tier the bearer token resolved to — M0 decision A3, no dedicated
// endpoint).
type capabilitiesProbe struct {
	AuthTier string `json:"auth_tier"`
	Server   struct {
		Name    string `json:"name"`
		Version string `json:"version"`
		BaseURL string `json:"base_url"`
	} `json:"server"`
}

// metaProbe is the subset of GET /v1/meta connect surfaces in its summary.
type metaProbe struct {
	ServerTime    string `json:"serverTime"`
	MinAPIVersion string `json:"minApiVersion"`
	MaxAPIVersion string `json:"maxApiVersion"`
}

// executeConnect points the CLI at an existing server: it confirms the server is
// reachable (GET /v1/capabilities + GET /v1/meta) and resolves the caller tier,
// then — unless DryRun — persists the connection so `bp` defaults here.
//
// On DryRun it does NOT touch the network beyond the reachability probe is
// skipped entirely: a dry run prints exactly what it WOULD save without
// connecting or writing, so it works offline.
func executeConnect(plan SetupPlan, opts Options) error {
	w := opts.out()
	server := strings.TrimRight(plan.Server, "/")

	saved := SavedConfig{
		Server:    server,
		Token:     plan.Token,
		Workspace: firstNonEmpty(plan.Workspace, "default"),
		Project:   firstNonEmpty(plan.Project, "default"),
		Dataset:   firstNonEmpty(plan.Dataset, "production"),
	}

	if opts.DryRun {
		// JSON dry-run is rendered by the caller from BuildPlan; print nothing.
		if !opts.json() {
			fmt.Fprintf(w, "dry-run: would connect to %s\n", server)
			fmt.Fprintf(w, "  scope:  w=%s p=%s d=%s\n", saved.Workspace, saved.Project, saved.Dataset)
			fmt.Fprintf(w, "  token:  %s\n", redactToken(saved.Token))
			fmt.Fprintf(w, "  would write %s and default bp here (no network call, no write)\n", configHint())
		}
		return nil
	}

	// Reachability + tier probe.
	tier, srvName, srvVersion, err := probeCapabilities(server, plan.Token)
	if err != nil {
		return fmt.Errorf("connect to %s failed: %w\n  hint: check the URL is reachable and the token (if any) is valid", server, err)
	}
	meta := probeMeta(server, plan.Token) // best-effort; summary still renders without it

	if opts.Store == nil {
		return fmt.Errorf("connect: no config store wired (internal error)")
	}
	if err := opts.Store.Save(saved); err != nil {
		return fmt.Errorf("connect: persist config: %w", err)
	}

	// Record the structured outcome for a JSON caller (no-op on the human path).
	opts.setResult(Result{
		OK:         true,
		Target:     TargetConnect,
		Server:     server,
		Tier:       tier,
		ConfigPath: configHint(),
		Message:    "connected to " + server + " as " + tier + "; bp now defaults here",
	})
	if opts.json() {
		return nil
	}

	// Premium summary.
	name := srvName
	if name == "" {
		name = "barkpark"
	}
	fmt.Fprintf(w, "✓ connected to %s as %s; bp now defaults here\n", server, tier)
	fmt.Fprintf(w, "  server: %s", name)
	if srvVersion != "" {
		fmt.Fprintf(w, " (%s)", srvVersion)
	}
	fmt.Fprintln(w)
	fmt.Fprintf(w, "  scope:  w=%s p=%s d=%s\n", saved.Workspace, saved.Project, saved.Dataset)
	if meta.ServerTime != "" {
		fmt.Fprintf(w, "  time:   %s\n", meta.ServerTime)
	}
	if meta.MinAPIVersion != "" {
		fmt.Fprintf(w, "  api:    %s..%s\n", meta.MinAPIVersion, meta.MaxAPIVersion)
	}
	return nil
}

// buildConnectPlan builds the structured dry-run plan for connect. Connect has a
// single conceptual step (write the config + default bp here); no network call,
// no destructive action, no confirm required.
func buildConnectPlan(plan SetupPlan, _ Options) Plan {
	server := strings.TrimRight(plan.Server, "/")
	saved := SavedConfig{
		Server:    server,
		Token:     plan.Token,
		Workspace: firstNonEmpty(plan.Workspace, "default"),
		Project:   firstNonEmpty(plan.Project, "default"),
		Dataset:   firstNonEmpty(plan.Dataset, "production"),
	}
	p := Plan{
		Target:    TargetConnect,
		DryRun:    true,
		Plugins:   planPlugins(plan.Plugins),
		ConnectTo: server,
		Env:       map[string]string{},
	}
	p.addStep(fmt.Sprintf("write %s and default bp here (scope w=%s p=%s d=%s, token %s)",
		configHint(), saved.Workspace, saved.Project, saved.Dataset, redactToken(saved.Token)), "")
	return p
}

// probeCapabilities GETs /v1/capabilities and returns the caller's resolved tier
// plus the server identity. A non-2xx or unparseable body is an error — that is
// the "server unreachable / not a barkpark server" signal connect surfaces.
func probeCapabilities(server, token string) (tier, name, version string, err error) {
	client := apiclient.New(apiclient.Config{BaseURL: server, Token: token})
	res, gerr := client.GetConditional(server+"/v1/capabilities", "")
	if gerr != nil {
		return "", "", "", gerr
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return "", "", "", fmt.Errorf("GET /v1/capabilities returned status %d", res.StatusCode)
	}
	var cap capabilitiesProbe
	if jerr := json.Unmarshal(res.Body, &cap); jerr != nil {
		return "", "", "", fmt.Errorf("parse /v1/capabilities: %w", jerr)
	}
	tier = cap.AuthTier
	if tier == "" {
		tier = "anonymous"
	}
	return tier, cap.Server.Name, cap.Server.Version, nil
}

// probeMeta GETs /v1/meta best-effort. A failure returns a zero metaProbe; the
// connect summary degrades gracefully without it.
func probeMeta(server, token string) metaProbe {
	client := apiclient.New(apiclient.Config{BaseURL: server, Token: token})
	res, err := client.GetConditional(server+"/v1/meta", "")
	if err != nil || res.StatusCode < 200 || res.StatusCode >= 300 {
		return metaProbe{}
	}
	var m metaProbe
	_ = json.Unmarshal(res.Body, &m)
	return m
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func redactToken(t string) string {
	if t == "" {
		return "(none — anonymous reads)"
	}
	return "****"
}

func configHint() string {
	return "${XDG_CONFIG_HOME:-~/.config}/barkpark/config.json"
}
