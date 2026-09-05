package cli

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runTinker is the `bp tinker [--dataset <ds>] [--perspective <p>]` built-in: an
// interactive, authenticated REPL against a live dataset. It resolves the same
// server/workspace/project/dataset/token context as every other command, loads
// the dataset's schema names once, then offers a thin read/write shell:
//
//	schemas              list the dataset's content types
//	query <type>         GET the type's documents (in the active perspective)
//	doc <type> <id>      GET one document
//	mutate <json>        POST a mutations body (createOrReplace wrapper added if
//	                     you pass a bare document with an _id)
//	perspective [p]      show, or switch to, published|drafts|raw
//	help                 show this list
//	exit | quit          leave
//
// Reads default to the `drafts` perspective when a token is configured (so docs
// you just `bp seed`-ed are visible, matching Studio/TUI), or `published` when
// anonymous.
//
// Each command builds a SCOPED url (the flat manifest.BuildURL is inert in v1)
// and prints the JSON envelope or the classified error. The readline loop is a
// thin shell; line parsing is factored into parseTinkerLine for tests.
//
// args is everything after the `tinker` noun (rest[1:] in Execute).
func runTinker(out *writer, g globals, ctx manifest.Context, args []string) int {
	if g.help {
		tinkerHelp(out)
		return exitOK
	}
	dataset := ""
	perspective := ""
	i := 0
	for i < len(args) {
		a := args[i]
		key, inlineVal, hasInline := splitFlagToken(a)
		switch key {
		case "--dataset", "-d":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--dataset")
			if err != nil {
				out.userErr("%v", err)
				return exitUsage
			}
			dataset = v
			i = ni
		case "--perspective", "-P":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--perspective")
			if err != nil {
				out.userErr("%v", err)
				return exitUsage
			}
			if !validPerspective(v) {
				out.userErr("invalid --perspective %q (want published|drafts|raw)", v)
				return exitUsage
			}
			perspective = v
			i = ni
		default:
			if strings.HasPrefix(a, "-") && a != "-" {
				out.userErr("unknown tinker flag %q", a)
				return exitUsage
			}
			i++
		}
	}
	if dataset == "" {
		dataset = ctx.Dataset
	}
	if dataset == "" {
		dataset = "production"
	}
	if perspective == "" {
		// Dev default: with a token, show `drafts` (what Studio/TUI show — so the
		// docs you just `bp seed`-ed are visible). Without a token, only the public
		// `published` perspective is readable, so default to that.
		if ctx.Token != "" {
			perspective = "drafts"
		} else {
			perspective = "published"
		}
	}

	// Load schema names once (best-effort — a down server still gets a REPL).
	schemaNames := tinkerSchemaNames(ctx, dataset)

	out.errf("bp tinker — %s [dataset %s · perspective %s]", ctx.Server, dataset, perspective)
	out.errf("type `help` for commands, `exit` to leave.")
	if len(schemaNames) > 0 {
		out.errf("types: %s", strings.Join(schemaNames, ", "))
	}

	scanner := bufio.NewScanner(os.Stdin)
	for {
		fmt.Fprint(out.stderr, "tinker> ")
		if !scanner.Scan() {
			break // EOF (Ctrl-D)
		}
		verb, rest, _ := parseTinkerLine(scanner.Text())
		switch verb {
		case "":
			continue
		case "exit", "quit":
			return exitOK
		case "help", "?":
			tinkerHelp(out)
		case "schemas", "types":
			if len(schemaNames) == 0 {
				out.outf("(no schemas loaded — server unreachable or empty dataset)")
				continue
			}
			for _, name := range schemaNames {
				out.outf("%s", name)
			}
		case "query":
			if rest == "" {
				out.errf("usage: query <type>")
				continue
			}
			typ := strings.Fields(rest)[0]
			u := ctxScopedURL(ctx, "/v1/data/query/"+url.PathEscape(dataset)+"/"+url.PathEscape(typ)) + "?perspective=" + url.QueryEscape(perspective)
			tinkerRequest(out, "GET", u, ctxAuthHeaders(ctx), nil)
		case "doc":
			parts := strings.Fields(rest)
			if len(parts) < 2 {
				out.errf("usage: doc <type> <id>")
				continue
			}
			u := ctxScopedURL(ctx, "/v1/data/doc/"+url.PathEscape(dataset)+"/"+url.PathEscape(parts[0])+"/"+url.PathEscape(parts[1])) + "?perspective=" + url.QueryEscape(perspective)
			tinkerRequest(out, "GET", u, ctxAuthHeaders(ctx), nil)
		case "perspective":
			if rest == "" {
				out.outf("perspective: %s  (set with: perspective <published|drafts|raw>)", perspective)
				continue
			}
			p := strings.Fields(rest)[0]
			if !validPerspective(p) {
				out.errf("invalid perspective %q — want published|drafts|raw", p)
				continue
			}
			perspective = p
			out.outf("perspective → %s", perspective)
		case "mutate":
			body := tinkerMutateBody(rest)
			if body == nil {
				out.errf("usage: mutate <json>  (a {\"mutations\":[…]} body, or a bare document)")
				continue
			}
			u := ctxScopedURL(ctx, "/v1/data/mutate/"+url.PathEscape(dataset))
			h := ctxAuthHeaders(ctx)
			h["Content-Type"] = "application/json"
			tinkerRequest(out, "POST", u, h, body)
		default:
			if best, ok := tinkerSuggest(verb); ok {
				out.errf("unknown command %q — did you mean `%s`? (type `help`)", verb, best)
			} else {
				out.errf("unknown command %q — type `help`", verb)
			}
		}
	}
	return exitOK
}

// parseTinkerLine splits a REPL line into its verb and the raw remainder. The
// remainder is kept verbatim (not re-tokenised) so a `mutate` JSON payload with
// embedded spaces survives intact. A blank line yields an empty verb. It is a
// tinkerCommands is the REPL's command vocabulary — the candidate set for the
// unknown-command "did you mean?" hint (via the same nearestToken edit-distance
// matcher the CLI's noun/verb hints use). Aliases like "?" are omitted; they are
// not words a user would mistype toward.
var tinkerCommands = []string{"query", "doc", "perspective", "mutate", "schemas", "types", "help", "exit", "quit"}

// tinkerSuggest returns the REPL command closest to a mistyped verb when it is
// close enough to be a likely typo (e.g. "quer" → "query"), else ("", false).
func tinkerSuggest(verb string) (string, bool) {
	return nearestToken(verb, tinkerCommands)
}

// PURE function — the unit test drives it directly; the readline loop stays a
// thin shell.
func parseTinkerLine(line string) (verb, rest string, err error) {
	line = strings.TrimSpace(line)
	if line == "" {
		return "", "", nil
	}
	parts := strings.SplitN(line, " ", 2)
	verb = parts[0]
	if len(parts) > 1 {
		rest = strings.TrimSpace(parts[1])
	}
	return verb, rest, nil
}

// tinkerMutateBody turns the `mutate` argument into a request body. A payload
// that already carries a "mutations" key is sent verbatim; a bare document
// object (one with an _id) is wrapped in a single createOrReplace mutation.
// Invalid/empty JSON returns nil so the caller prints usage.
func tinkerMutateBody(arg string) []byte {
	arg = strings.TrimSpace(arg)
	if arg == "" {
		return nil
	}
	var v map[string]any
	if err := json.Unmarshal([]byte(arg), &v); err != nil {
		return nil
	}
	if _, ok := v["mutations"]; ok {
		return []byte(arg)
	}
	// Bare document → wrap as createOrReplace.
	b, err := json.Marshal(map[string]any{"mutations": []map[string]any{{"createOrReplace": v}}})
	if err != nil {
		return nil
	}
	return b
}

// tinkerRequest sends one REPL request and prints the JSON envelope on success
// or the classified error (plus its humane hint) on failure.
func tinkerRequest(out *writer, method, u string, headers map[string]string, body []byte) {
	status, respBody, err := doRequest(method, u, headers, body)
	if err != nil {
		out.errf("request failed: %v", err)
		return
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, respBody)
		out.errf("error: %s", ae.errorMessage())
		if h := ae.hint(); h != "" {
			out.errf("  hint: %s", h)
		}
		return
	}
	// The REPL's `mutate` is a WRITE, and out.renderRaw over an empty 200
	// printed NOTHING and dropped straight back to the prompt — which in a REPL
	// reads as "it worked".
	//
	// GATED ON THE METHOD, and that gate is load-bearing: tinkerRequest is
	// SHARED with `query` and `doc`, and the write verdict refuses an empty JSON
	// array. An honest query that matches nothing answers exactly `[]`, so
	// screening the reads here would turn "no rows" into a refusal — the read
	// arm of the fence is a DIFFERENT predicate (unreadableReadPage) and is not
	// this task's seam.
	if method != "GET" && method != "HEAD" {
		if _, handled := screenBuiltinWriteReceipt(out, "tinker "+strings.ToLower(method), status, respBody); handled {
			return
		}
	}
	out.renderRaw(respBody)
}

// tinkerSchemaNames fetches and sorts the dataset's schema names for the prompt
// banner and the `schemas` command. Best-effort: a failure yields an empty
// slice and the REPL still opens.
func tinkerSchemaNames(ctx manifest.Context, dataset string) []string {
	u := ctxScopedURL(ctx, "/v1/schemas/"+url.PathEscape(dataset))
	status, body, err := doRequest("GET", u, ctxAuthHeaders(ctx), nil)
	if err != nil || status < 200 || status >= 300 {
		return nil
	}
	var env struct {
		Schemas []struct {
			Name string `json:"name"`
		} `json:"schemas"`
	}
	if jerr := json.Unmarshal(body, &env); jerr != nil {
		return nil
	}
	names := make([]string, 0, len(env.Schemas))
	for _, s := range env.Schemas {
		if s.Name != "" {
			names = append(names, s.Name)
		}
	}
	sort.Strings(names)
	return names
}

func tinkerHelp(out *writer) {
	out.outf("commands:")
	out.outf("  schemas              list the dataset's content types")
	out.outf("  query <type>         fetch the type's documents (in the active perspective)")
	out.outf("  doc <type> <id>      fetch one document")
	out.outf("  mutate <json>        POST a mutations body (bare docs are wrapped in createOrReplace)")
	out.outf("  perspective [p]      show, or switch to, published|drafts|raw")
	out.outf("  help                 show this list")
	out.outf("  exit | quit          leave the REPL")
}

// validPerspective reports whether p is one of the three read perspectives the
// data API accepts. Pure function — driven directly by the unit test.
func validPerspective(p string) bool {
	switch p {
	case "published", "drafts", "raw":
		return true
	default:
		return false
	}
}
