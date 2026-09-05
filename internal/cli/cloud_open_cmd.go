package cli

// cloud_open_cmd.go is `bp cloud open <target>` — resolve a fleet target to its
// dashboard deep link and open it (epic charter, decision 14). It maps a target
// to a LEGACY-STABLE hash route only — #fleet, #sites, #activity,
// #instance/<id>, #site/<id> — never #settings/* or any future sub-route, so a
// URL minted into a terminal or a script outlives every IA reshape. It prints
// the URL ALWAYS (scripts read it); it opens the browser only on a tty, unless
// --print-only suppresses the launch entirely.

import (
	"errors"
	"fmt"
	"net/http"
	"os/exec"
	"runtime"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// browserOpener launches the OS browser on a URL. A package var (the
// newHetznerClient seam idiom) so tests observe the open without spawning a real
// browser.
var browserOpener = openInBrowser

// openInBrowser opens url in the user's default browser, per OS. It Start()s the
// helper (never Wait) so `bp` returns immediately.
func openInBrowser(url string) error {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", url).Start()
	case "windows":
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	default:
		return exec.Command("xdg-open", url).Start()
	}
}

// openHash resolves a target kind + already-resolved id to its legacy-stable
// dashboard hash (charter decision 14). The three tabs (fleet/sites/activity)
// take no id; the two drill-downs (instance/site) require one. It is pure — the
// single place the hash vocabulary is minted — so a test can pin every form.
func openHash(kind, id string) (string, error) {
	switch kind {
	case "fleet", "sites", "activity":
		if id != "" {
			return "", fmt.Errorf("target %q takes no id (usage: bp cloud open %s)", kind, kind)
		}
		return "#" + kind, nil
	case "instance":
		if id == "" {
			return "", fmt.Errorf("target instance needs an <id-or-name> (usage: bp cloud open instance <id-or-name>)")
		}
		return "#instance/" + id, nil
	case "site":
		if id == "" {
			return "", fmt.Errorf("target site needs an <id-or-name> (usage: bp cloud open site <id-or-name>)")
		}
		return "#site/" + id, nil
	default:
		return "", fmt.Errorf("unknown target %q (want fleet|sites|activity|instance <id>|site <id>)", kind)
	}
}

// dashboardBaseURL is the SPA origin the hash hangs off: the saved CloudURL
// (the control plane serves the dashboard at its root) or the baked default.
func dashboardBaseURL(cfg *Config) string {
	base := ""
	if cfg != nil {
		base = strings.TrimSpace(cfg.CloudURL)
	}
	if base == "" {
		base = cloudclient.DefaultBaseURL
	}
	return strings.TrimRight(base, "/")
}

// dashboardURL joins the dashboard base origin with a hash route. The dashboard
// is hash-routed off the SPA shell at "/", so the deep link is `<base>/<hash>`.
func dashboardURL(base, hash string) string {
	return strings.TrimRight(base, "/") + "/" + hash
}

// looksLikeUUID reports whether s is a canonical 8-4-4-4-12 hex UUID. When the
// caller already holds an id, `bp cloud open instance <uuid>` needs no network;
// only a NAME triggers a list-endpoint resolve.
func looksLikeUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, r := range s {
		switch i {
		case 8, 13, 18, 23:
			if r != '-' {
				return false
			}
		default:
			isHex := (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')
			if !isHex {
				return false
			}
		}
	}
	return true
}

// runCloudOpen is `bp cloud open <target> [<id-or-name>] [--print-only]`.
func runCloudOpen(out *writer, g globals, args []string) int {
	if g.help {
		printCloudOpenHelp(out)
		return exitOK
	}
	const usage = "bp cloud open fleet|sites|activity|instance <id-or-name>|site <id-or-name> [--print-only]"

	printOnly := false
	pos := make([]string, 0, len(args))
	for _, a := range args {
		switch {
		case a == "--print-only":
			printOnly = true
		case strings.HasPrefix(a, "-") && a != "-":
			return useError(out, "usage", fmt.Sprintf("unknown flag %q (usage: %s)", a, usage), exitUsage)
		default:
			pos = append(pos, a)
		}
	}
	if len(pos) == 0 {
		return useError(out, "usage", "missing target (usage: "+usage+")", exitUsage)
	}
	if len(pos) > 2 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", pos[2], usage), exitUsage)
	}
	kind := pos[0]
	ref := ""
	if len(pos) == 2 {
		ref = pos[1]
	}

	cfg, err := LoadConfig()
	if err != nil {
		return useError(out, "failed", "read config: "+err.Error(), exitGeneric)
	}

	// Resolve a name/slug to its id for the drill-down targets. A bare id (UUID)
	// or any fleet/sites/activity tab needs no network. An empty ref falls
	// through unresolved so openHash emits the precise "needs an <id>" usage
	// error rather than a generic resolve failure.
	id := ref
	switch {
	case kind == "instance" && ref != "":
		rid, rerr := resolveOpenBarkparkID(cfg, ref)
		if rerr != nil {
			return openResolveFail(out, rerr)
		}
		id = rid
	case kind == "site" && ref != "":
		rid, rerr := resolveOpenSiteID(cfg, ref)
		if rerr != nil {
			return openResolveFail(out, rerr)
		}
		id = rid
	}

	hash, herr := openHash(kind, id)
	if herr != nil {
		return useError(out, "usage", herr.Error(), exitUsage)
	}
	url := dashboardURL(dashboardBaseURL(cfg), hash)

	opened := false
	if !printOnly && out.isTTY {
		if berr := browserOpener(url); berr == nil {
			opened = true
		} else {
			// Opening is best-effort: the URL is already the deliverable. Note the
			// failure on stderr but do NOT fail the command.
			out.errf("could not open a browser (%v) — copy the URL above", berr)
		}
	}

	if out.output == "json" || out.output == "yaml" {
		out.emitStructured(map[string]any{
			"ok":     true,
			"target": kind,
			"url":    url,
			"opened": opened,
		})
		return exitOK
	}

	out.outf("%s", url)
	if opened {
		out.info("opening in your browser…")
	}
	return exitOK
}

// openResolveErr is a name-resolution failure that CARRIES its class instead of
// spelling it. The class is a declared field precisely because the sentence
// cannot be trusted to answer for it: every one of these messages interpolates
// the caller's own ref (`no site matches %q`), so a ref that happens to spell
// "unauthorized" — a site named `unauthorized-page`, say — made the old
// substring ladder read a NOT-FOUND as an auth failure and tell the operator to
// re-run `bp login` for a name that simply does not exist. Same shape as
// siteRefusalFail's fix (cloud_site_cmd.go): the evidence was already on hand
// and only the last inch discarded it.
type openResolveErr struct {
	// class is what the CLI's exit scheme needs to know, and the ONLY thing it
	// reads. "auth" → exitAuth, "not_found" → exitNotFound.
	class string
	msg   string
}

func (e *openResolveErr) Error() string { return e.msg }

// openAuthErr / openNotFoundErr are the two constructors, spelled so a call site
// states the class next to the sentence it produces and cannot leave it blank.
func openAuthErr(format string, args ...any) error {
	return &openResolveErr{class: "auth", msg: fmt.Sprintf(format, args...)}
}

func openNotFoundErr(format string, args ...any) error {
	return &openResolveErr{class: "not_found", msg: fmt.Sprintf(format, args...)}
}

// resolveOpenBarkparkID turns an instance id-or-name into its id. A UUID passes
// through untouched (no network); a name/slug is resolved via GET /v1/barkparks,
// which needs a Cloud token.
func resolveOpenBarkparkID(cfg *Config, ref string) (string, error) {
	if strings.TrimSpace(ref) == "" {
		return "", fmt.Errorf("instance needs an <id-or-name>")
	}
	if looksLikeUUID(ref) {
		return ref, nil
	}
	if !cfg.HasCloudToken() {
		return "", openAuthErr("not logged in — run `bp login` to resolve %q by name (or pass its id), or set BARKPARK_CLOUD_TOKEN for a CI job", ref)
	}
	list, err := cfg.CloudClient().ListBarkparks(cloudCtx())
	if err != nil {
		return "", err
	}
	// Exact id/slug/name first — an exact match must never lose to an earlier
	// case-folded one — then a case-insensitive name pass as a convenience.
	for _, b := range list {
		if b.ID == ref || b.Slug == ref || b.Name == ref {
			return b.ID, nil
		}
	}
	for _, b := range list {
		if strings.EqualFold(b.Name, ref) {
			return b.ID, nil
		}
	}
	return "", openNotFoundErr("no Barkpark matches %q (see `bp cloud status`)", ref)
}

// resolveOpenSiteID turns a site id-or-name into its id, mirroring
// resolveOpenBarkparkID over GET /v1/sites.
func resolveOpenSiteID(cfg *Config, ref string) (string, error) {
	if strings.TrimSpace(ref) == "" {
		return "", fmt.Errorf("site needs an <id-or-name>")
	}
	if looksLikeUUID(ref) {
		return ref, nil
	}
	if !cfg.HasCloudToken() {
		return "", openAuthErr("not logged in — run `bp login` to resolve %q by name (or pass its id), or set BARKPARK_CLOUD_TOKEN for a CI job", ref)
	}
	list, err := cfg.CloudClient().ListSites(cloudCtx())
	if err != nil {
		return "", err
	}
	// Exact first, then case-insensitive — same rule as instances.
	for _, s := range list {
		if s.ID == ref || s.Slug == ref || s.Name == ref {
			return s.ID, nil
		}
	}
	for _, s := range list {
		if strings.EqualFold(s.Name, ref) {
			return s.ID, nil
		}
	}
	return "", openNotFoundErr("no site matches %q (see `bp sites`)", ref)
}

// openResolveFail maps a name-resolution failure onto the CLI's exit scheme: the
// resolvers' own DECLARED outcomes carry their class, a control-plane refusal
// carries its HTTP STATUS, and anything else (a transport error, a gateway page)
// is generic. The message is unchanged in every arm — only how the exit code is
// decided moved.
//
// IT USED TO SUBSTRING-MATCH THE RENDERED SENTENCE, and that sentence is not the
// CLI's to pattern-match: `no Barkpark matches %q` / `no site matches %q`
// interpolate the caller's OWN ref, so `bp cloud open site unauthorized-page`
// hit the auth arm on a name that resolved to nothing — the operator was told
// their session had expired and handed exit 3 while stderr said, in the same
// breath, "no site matches". Both facts were already declared: the two local
// outcomes are produced by known branches (now openAuthErr / openNotFoundErr)
// and the ONLY wire-borne auth failure that can reach here is a 401, which
// arrives as a typed *cloudclient.CloudRefusal — ListBarkparks and ListSites
// both route every non-2xx through cloudError. Nothing has to read the prose.
func openResolveFail(out *writer, err error) int {
	msg := err.Error()
	var re *openResolveErr
	if errors.As(err, &re) {
		switch re.class {
		case "auth":
			return useError(out, "auth", msg, exitAuth)
		case "not_found":
			return useError(out, "not_found", msg, exitNotFound)
		}
	}
	// A control-plane refusal grades on its STATUS, not its words: a 401 is the
	// credential, and every other refusal (403 forbidden, 404 route missing, 5xx)
	// is not something `bp login` fixes.
	var refusal *cloudclient.CloudRefusal
	if errors.As(err, &refusal) && refusal.HTTPStatus == http.StatusUnauthorized {
		return useError(out, "auth", msg, exitAuth)
	}
	return useError(out, "failed", msg, exitGeneric)
}

// printCloudOpenHelp writes `bp cloud open` usage.
func printCloudOpenHelp(out *writer) {
	const help = `bp cloud open — open (or print) a dashboard deep link (charter decision 14).

USAGE
  bp cloud open fleet
  bp cloud open sites
  bp cloud open activity
  bp cloud open instance <id-or-name>
  bp cloud open site <id-or-name>
  [--print-only]

WHAT IT DOES
  resolves the target to a legacy-stable dashboard hash link — #fleet, #sites,
  #activity, #instance/<id>, #site/<id> — and opens it in your browser. The URL
  is always emitted (bare on a tty, in the json envelope when piped), so it
  works in a script; the browser is only launched on a tty. A name is resolved
  to its id via the fleet/sites list (needs 'bp login'); a bare id opens with
  no network call.

FLAGS
  --print-only   print the URL, never open a browser
  -o json        emit {ok, target, url, opened}`
	out.outf("%s", help)
}
