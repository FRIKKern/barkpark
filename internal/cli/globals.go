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

	// manifestPath is the --manifest <path> override: load the manifest from a
	// local file instead of GET /v1/capabilities. Lets the CLI run before the
	// capabilities endpoint is deployed. Empty means no override.
	manifestPath string
}

// globalSpec maps a long/short flag to whether it takes a value. Hand-rolled so
// we can split cleanly at the first positional (the noun).
var valueFlags = map[string]bool{
	"-s": true, "--server": true,
	"-w": true, "--workspace": true,
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
	"--yes": true, "--all": true,
	"-h": true, "--help": true,
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

		val := inlineVal
		if takesValue && !hasInline {
			if i+1 >= len(args) {
				return g, nil, fmt.Errorf("flag %q needs a value", key)
			}
			val = args[i+1]
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
	case "-w", "--workspace":
		g.workspace = val
	case "-p", "--project":
		g.project = val
	case "-d", "--dataset":
		g.dataset = val
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
	case "--limit":
		n, err := strconv.Atoi(val)
		if err != nil {
			return fmt.Errorf("invalid --limit %q", val)
		}
		g.limit = n
		g.limitSet = true
	case "--offset":
		n, err := strconv.Atoi(val)
		if err != nil {
			return fmt.Errorf("invalid --offset %q", val)
		}
		g.offset = n
		g.offsetSet = true
	case "-h", "--help":
		g.help = true
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
