package cli

import (
	"fmt"
	"strconv"
	"strings"
)

// globals are the CLI-wide flags parsed BEFORE the noun/verb. They are
// hand-parsed (not flag.FlagSet) so they can stop at the first non-flag token
// — the noun — and hand the remainder to the manifest-driven dispatcher
// untouched. Command-local flags (from the manifest) are parsed later by the
// command runner.
type globals struct {
	server    string
	token     string // --token: explicit bearer token; wins over a named server's saved token
	workspace string
	project   string
	dataset   string
	output    string // table | json | yaml | minimal

	jsonOut bool // --json: shorthand for -o json
	quiet   bool // -q: minimal receipt on writes
	verbose bool // -v
	noColor bool // --no-color
	dryRun  bool // --dry-run: print the request, do not send (M0 decision A1)
	yes     bool // --yes: skip the prod write-guard confirm
	help    bool // -h/--help
	version bool // --version/-V: print the CLI version and exit
	full    bool // --full: force the full server view even where a brief agent default applies

	// view is the request-side response projection: applyQuery appends ?view=
	// when it is non-empty. The CLI resolves it in runCommand (resolveView —
	// brief for machine output on a command whose manifest declares views);
	// the MCP handlers set it directly on their local globals copy. Never a
	// user flag — --full is the user-facing escape hatch.
	view string

	// Pagination knobs. Present? tracked so a command can tell "user set --limit"
	// from "user left it default".
	limit     int
	limitSet  bool
	offset    int
	offsetSet bool
	all       bool

	// outputSet records whether -o/--output (or --json) was explicit, so the
	// runner can fall back to the tty-vs-pipe default only when the user did not
	// choose.
	outputSet bool

	// datasetSet records whether -d/--dataset was TYPED IN ARGV, as opposed to
	// dataset merely holding a value some other layer supplied. It exists for
	// the verbs whose OWN --dataset flag the global parser eats: parseGlobals
	// consumes -d/--dataset wherever it appears (by design — the global scope
	// triple may sit before or after the noun), so a command-local `dataset`
	// flag can never see it and must read g.dataset instead. Reading g.dataset
	// UNCONDITIONALLY is the trap (cloud_site_cmd.go:163): the resolved content
	// context also carries an ambient dataset from ~/.config/barkpark/config.json
	// / BARKPARK_DATASET, so an unflagged `bp cloud workspace export --profile dev`
	// would silently become dataset-narrowed by the operator's saved context —
	// one silent wrong answer traded for another. Only an explicitly-typed flag
	// may scope a bundle, and this bit is how a verb tells the difference.
	datasetSet bool

	// noCache is --no-cache: bypass the on-disk capabilities manifest cache for
	// BOTH the read and the write. It is the diagnostic escape hatch for the
	// fresh window (manifest.DefaultManifestTTL) — the one thing an operator can
	// type to be certain the command tree in front of them came from the server
	// this second, and the answer to "the server changed and bp has not noticed
	// yet". Bypassing the WRITE too is deliberate: a --no-cache run must leave
	// the cache exactly as it found it, so it diagnoses the cache instead of
	// silently repairing it.
	noCache bool

	// manifestPath is the --manifest <path> override: load the manifest from a
	// local file instead of GET /v1/capabilities. Lets the CLI run before the
	// capabilities endpoint is deployed. Empty means no override.
	manifestPath string
}

// globalSpec maps a long/short flag to whether it takes a value. Hand-rolled so
// we can split cleanly at the first positional (the noun).
var valueFlags = map[string]bool{
	"-s": true, "--server": true,
	"--token": true,
	"-w":      true, "--workspace": true,
	"-p": true, "--project": true,
	"-d": true, "--dataset": true,
	"-o": true, "--output": true,
	"--limit": true, "--offset": true,
	"--manifest": true,
}

var boolFlags = map[string]bool{
	"--json": true, "-q": true, "--quiet": true,
	"-v": true, "--verbose": true,
	"--no-color": true, "--dry-run": true,
	"--yes": true, "--all": true, "--full": true,
	"--no-cache": true,
	"-h":         true, "--help": true,
	"--version": true, "-V": true,
}

// isKnownGlobalFlag reports whether tok resolves to a global flag parseGlobals
// recognises — a bare short/long flag, or a long flag carrying an inline
// `--flag=value`. Used to guard against consuming a following known flag as a
// value.
func isKnownGlobalFlag(tok string) bool {
	key := tok
	if eq := strings.IndexByte(tok, '='); eq >= 0 && strings.HasPrefix(tok, "--") {
		key = tok[:eq]
	}
	return valueFlags[key] || boolFlags[key]
}

// parseGlobals extracts recognised global flags from anywhere in args and
// returns the remaining tokens (noun, verb, positionals, and command-local
// flags) as rest, in order. Global flags may appear before OR after the noun —
// `barkpark doc ls post -o json` works the same as `barkpark -o json doc ls
// post`. An UNRECOGNISED `--flag` (or a token that is not a global flag) is
// passed through to rest untouched, so a command-local flag the manifest
// declares (and any positional) reaches the command runner. The very first
// unrecognised token is the noun; the global parser does not special-case it —
// it just collects whatever is not a known global into rest.
//
// One subtlety: a token that is NOT a known global flag and does NOT start with
// '-' (a positional) might be the value of an unknown command-local flag we
// just passed through. We can't know command-local flag arity here (that needs
// the manifest), so we never consume a value for an unknown flag — command-local
// flag/value pairing is resolved later in splitArgs. We only consume values for
// KNOWN global value-flags.
func parseGlobals(args []string) (globals, []string, error) {
	g := globals{}
	var rest []string
	i := 0
	for i < len(args) {
		a := args[i]

		// Plain positional or bare "-": passes through to rest.
		if a == "" || a[0] != '-' || a == "-" {
			rest = append(rest, a)
			i++
			continue
		}

		// Support --flag=value form.
		key := a
		inlineVal := ""
		hasInline := false
		if eq := strings.IndexByte(a, '='); eq >= 0 && strings.HasPrefix(a, "--") {
			key = a[:eq]
			inlineVal = a[eq+1:]
			hasInline = true
		}

		takesValue := valueFlags[key]
		isBool := boolFlags[key]
		if !takesValue && !isBool {
			// Not a global flag — a command-local flag (or its '-' value). Pass
			// the token through verbatim; the command runner pairs it.
			rest = append(rest, a)
			i++
			continue
		}

		// An inline value on a bool flag (`--yes=false`) is a usage error, not a
		// silently-ignored token: set() discards val for bools, so accepting it
		// would make `--yes=false` set g.yes=true — the exact opposite of intent,
		// silently defeating the prod write-guard. Reject it (exit 2).
		if isBool && hasInline {
			return g, nil, fmt.Errorf("flag %q takes no value", key)
		}

		val := inlineVal
		if takesValue && !hasInline {
			if i+1 >= len(args) {
				return g, nil, fmt.Errorf("flag %q needs a value", key)
			}
			next := args[i+1]
			// A following token that is itself a KNOWN global flag (-v,
			// --output, ...) is never a legitimate value for this flag — it
			// means the caller forgot the value. Binding it anyway produces a
			// confusing downstream error (e.g. invalid --output "-v") instead
			// of the real complaint. A token that merely starts with '-' but
			// is not a known global flag (a negative number, an unknown
			// command-local flag) is still accepted as a value below.
			if next != "-" && strings.HasPrefix(next, "-") && isKnownGlobalFlag(next) {
				return g, nil, fmt.Errorf("flag %q needs a value", key)
			}
			val = next
			i++
		}

		if err := g.set(key, val); err != nil {
			return g, nil, err
		}
		i++
	}
	return g, rest, nil
}

// set applies one parsed flag. Bool flags ignore val.
func (g *globals) set(key, val string) error {
	switch key {
	case "-s", "--server":
		g.server = val
	case "--token":
		g.token = val
	case "-w", "--workspace":
		g.workspace = val
	case "-p", "--project":
		g.project = val
	case "-d", "--dataset":
		g.dataset = val
		g.datasetSet = true
	case "-o", "--output":
		if !validOutput(val) {
			return fmt.Errorf("invalid --output %q (want table|json|yaml|minimal)", val)
		}
		g.output = val
		g.outputSet = true
	case "--manifest":
		g.manifestPath = val
	case "--json":
		g.jsonOut = true
		g.output = "json"
		g.outputSet = true
	case "-q", "--quiet":
		g.quiet = true
	case "-v", "--verbose":
		g.verbose = true
	case "--no-color":
		g.noColor = true
	case "--dry-run":
		g.dryRun = true
	case "--yes":
		g.yes = true
	case "--all":
		g.all = true
	case "--full":
		g.full = true
	case "--no-cache":
		g.noCache = true
	case "--limit":
		n, err := strconv.Atoi(val)
		if err != nil {
			return fmt.Errorf("invalid --limit %q", val)
		}
		if n < 0 {
			return fmt.Errorf("invalid --limit %q (must be >= 0)", val)
		}
		g.limit = n
		g.limitSet = true
	case "--offset":
		n, err := strconv.Atoi(val)
		if err != nil {
			return fmt.Errorf("invalid --offset %q", val)
		}
		if n < 0 {
			return fmt.Errorf("invalid --offset %q (must be >= 0)", val)
		}
		g.offset = n
		g.offsetSet = true
	case "-h", "--help":
		g.help = true
	case "--version", "-V":
		g.version = true
	default:
		return fmt.Errorf("unhandled global flag %q", key)
	}
	return nil
}

func validOutput(s string) bool {
	switch s {
	case "table", "json", "yaml", "minimal":
		return true
	}
	return false
}

// globalQueryForward is ONE global value flag that may ride the query string:
// the manifest flag name it answers to, whether the user actually TYPED it, and
// the value to send.
//
// It exists because every global value flag is invisible to the manifest-driven
// flag loop in applyQuery. parseGlobals consumes -d/--dataset, --limit and
// --offset wherever they appear in argv (by design — the global scope triple may
// sit before or after the noun), so `flags["dataset"]` is NEVER populated and a
// command that declares its own `dataset` flag can never see the one the caller
// typed. Before this table each such flag needed its own hand-written line in
// applyQuery, and each one was written only after a user had already been given
// a silently unfiltered answer: limit and offset first (six commands, all
// answering with the server's default at rc=0), then dataset on task.ready —
// the third instance of the same trap in a single day.
//
// The rule is DECLARATION-driven: the knob rides when the command's own
// manifest says it accepts that flag. Adding the next global value flag to
// globalQueryForwards is now the whole change; applyQuery does not grow a line.
type globalQueryForward struct {
	name  string
	set   bool
	value string

	// paginatedProtocol marks a knob that a `paginated: true` command takes as
	// PROTOCOL whether or not it also enumerates it as a flag — true for
	// limit/offset (the seven paginated commands), false for dataset, which a
	// route reads only where it declares it.
	paginatedProtocol bool
}

// globalQueryForwards is the table applyQuery iterates. Membership is gated on
// a "was it TYPED" bit, never on the value alone: g.dataset also holds the
// ambient dataset from ~/.config/barkpark/config.json / BARKPARK_DATASET, and
// forwarding THAT would narrow a request the caller never asked to narrow —
// one silent wrong answer traded for another (see datasetSet above). A global
// with no such bit therefore does not belong in this table.
func globalQueryForwards(g globals) []globalQueryForward {
	return []globalQueryForward{
		{name: "limit", set: g.limitSet, value: strconv.Itoa(g.limit), paginatedProtocol: true},
		{name: "offset", set: g.offsetSet, value: strconv.Itoa(g.offset), paginatedProtocol: true},
		{name: "dataset", set: g.datasetSet, value: g.dataset},
	}
}
