package setup

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

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
		Name:      strings.TrimSpace(plan.Name),
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
			fmt.Fprintf(w, "  would write %s, remember this server, and default bp here (no network call, no write)\n", configHint())
			writeKnownServersLine(w, opts.KnownServers)
		}
		return nil
	}

	// Reachability + tier probe.
	tier, srvName, srvVersion, err := probeCapabilities(server, plan.Token)
	if err != nil {
		if probe, ok := err.(*probeError); ok && probe.unauthorized {
			return fmt.Errorf("connect to %s failed: %w\n  hint: the server is reachable but rejected the token — check the token (tier must be at least read)", server, err)
		}
		return fmt.Errorf("connect to %s failed: %w\n  hint: check the URL is reachable and the token (if any) is valid", server, err)
	}
	// /v1/capabilities is a public endpoint: an INVALID token never 401s, it
	// just resolves to the anonymous tier. When the user explicitly supplied a
	// token, connecting "as none" is a failure — saving that token would make
	// every later write 401 — so refuse with the same hint the 401 path gives.
	// A tokenless connect resolving to the anonymous tier stays legitimate
	// (public read-only server).
	if plan.Token != "" && (tier == "none" || tier == "anonymous") {
		return fmt.Errorf(
			"connect to %s failed: the server is reachable but the token resolved to tier %q\n  hint: check the token — it was not accepted (tier must be at least read)",
			server, tier)
	}
	meta := probeMeta(server, plan.Token) // best-effort; summary still renders without it

	if opts.Store == nil {
		return fmt.Errorf("connect: no config store wired (internal error)")
	}
	// Stamp the connect time here (impure side: time.Now()) and hand the resolved
	// tier to the store so it lands on the remembered ServerEntry. The pure upsert
	// logic lives in cli.Config.RememberServer, which takes the timestamp as data.
	saved.Tier = tier
	saved.LastConnected = time.Now().UTC().Format(time.RFC3339)
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
		Profile:    plan.Profile,
		StudioURL:  server + "/studio",
		Next:       nextSteps(plan.Profile),
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
	writeKnownServersLine(w, opts.KnownServers)
	writeNextSteps(w, server, plan.Profile)
	return nil
}

// writeNextSteps prints the done-screen tail of a successful connect: the
// Studio URL plus the next-steps cheat block. The welcome-paper line renders
// only when this connect followed a clean-profile seed (the chaining executor
// stamps plan.Profile); a pure `--target connect` has no profile and omits it.
func writeNextSteps(w interface{ Write([]byte) (int, error) }, server, profile string) {
	fmt.Fprintf(w, "\n  studio:  %s/studio\n", server)
	fmt.Fprintf(w, "\nnext steps\n")
	fmt.Fprintf(w, "  bp doc ls                    list documents\n")
	if profile == ProfileClean {
		fmt.Fprintf(w, "  bp paper view welcome        read the welcome paper in your terminal\n")
	}
	fmt.Fprintf(w, "  bp setup                     re-run this wizard any time\n")
	fmt.Fprintf(w, "  bp help                      every command (manifest-driven)\n")
}

// nextSteps is the machine form of the next-steps block for the JSON Result.
func nextSteps(profile string) []string {
	next := []string{"bp doc ls"}
	if profile == ProfileClean {
		next = append(next, "bp paper view welcome")
	}
	return append(next, "bp setup", "bp help")
}

// writeKnownServersLine prints a tight one-line summary of the connect history.
// Empty history => nothing. The active server (if any) is starred.
func writeKnownServersLine(w interface{ Write([]byte) (int, error) }, known []KnownServerInfo) {
	if len(known) == 0 {
		return
	}
	parts := make([]string, 0, len(known))
	for _, s := range known {
		label := s.Server
		if s.Active {
			label = "★" + label
		}
		parts = append(parts, label)
	}
	fmt.Fprintf(w, "  known servers: %s\n", strings.Join(parts, ", "))
}

// buildConnectPlan builds the structured dry-run plan for connect. Connect has a
// single conceptual step (write the config + default bp here); no network call,
// no destructive action, no confirm required.
func buildConnectPlan(plan SetupPlan, opts Options) Plan {
	server := strings.TrimRight(plan.Server, "/")
	saved := SavedConfig{
		Server:    server,
		Token:     plan.Token,
		Workspace: firstNonEmpty(plan.Workspace, "default"),
		Project:   firstNonEmpty(plan.Project, "default"),
		Dataset:   firstNonEmpty(plan.Dataset, "production"),
	}
	p := Plan{
		Target:       TargetConnect,
		DryRun:       true,
		Plugins:      planPlugins(plan.Plugins),
		ConnectTo:    server,
		Env:          map[string]string{},
		KnownServers: knownServersForPlan(opts.KnownServers),
	}
	p.addStep(fmt.Sprintf("write %s, remember this server, and default bp here (scope w=%s p=%s d=%s, token %s)",
		configHint(), saved.Workspace, saved.Project, saved.Dataset, redactToken(saved.Token)), "")
	return p
}

// knownServersForPlan projects the connect history onto the credential-free
// PlanKnownServer view the JSON dry-run exposes.
func knownServersForPlan(known []KnownServerInfo) []PlanKnownServer {
	if len(known) == 0 {
		return nil
	}
	out := make([]PlanKnownServer, 0, len(known))
	for _, s := range known {
		out = append(out, PlanKnownServer{
			Server:        s.Server,
			Active:        s.Active,
			LastConnected: s.LastConnected,
		})
	}
	return out
}

// probeError is a typed error returned by probeCapabilities so callers can
// distinguish a token rejection (HTTP 401) from a general reachability failure.
type probeError struct {
	msg         string
	unauthorized bool // true when the server returned HTTP 401
}

func (e *probeError) Error() string { return e.msg }

// probeCapabilities GETs /v1/capabilities and returns the caller's resolved tier
// plus the server identity. A non-2xx or unparseable body is an error — that is
// the "server unreachable / not a barkpark server" signal connect surfaces.
// A 401 is returned as a *probeError with unauthorized=true so executeConnect
// can emit a more specific hint.
func probeCapabilities(server, token string) (tier, name, version string, err error) {
	client := apiclient.New(apiclient.Config{BaseURL: server, Token: token})
	res, gerr := client.GetConditional(server+"/v1/capabilities", "")
	if gerr != nil {
		return "", "", "", gerr
	}
	if res.StatusCode == 401 {
		return "", "", "", &probeError{
			msg:         fmt.Sprintf("GET /v1/capabilities returned status %d", res.StatusCode),
			unauthorized: true,
		}
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
