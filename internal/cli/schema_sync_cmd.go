package cli

// schema_sync_cmd.go is `bp schema pull|diff|push <dir>`: a dataset's schemas
// kept as one JSON file per schema in a folder, so they can live in git.
//
//   - pull writes the server's schemas into the folder.
//   - diff compares the folder to the server and exits 1 when they differ.
//   - push applies the folder to the server, and with --prune also deletes
//     the server schemas the folder does not have.
//
// The comparison and the plan are in schema_sync_plan.go. Reading the list and
// applying a schema reuse fetchDatasetSchemas and applySchemas from
// schema_copy.go, the same code `bp export --schemas` and `bp import
// --schemas` run.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// exitSchemaDiff is what `bp schema diff` returns when the folder and the
// server differ. The CLI had no code for "differences found"; 1 is what diff
// tools use, and a file that does not parse returns exitValidation instead.
const exitSchemaDiff = exitGeneric

func printSchemaPullHelp(out *writer) {
	out.outf("usage: bp schema pull <dir> [--prune] [--dry-run] [-o table|json|yaml]")
	out.outf("")
	out.outf("Writes every schema of the dataset to <dir>, one file per schema, named")
	out.outf("<name>.json. Keys are sorted and the server's schemaHash is left out, so")
	out.outf("the files are stable in git. The folder is created when it is missing.")
	out.outf("")
	out.outf("A schema file in <dir> whose schema is no longer on the server is kept and")
	out.outf("named. Only a regular <name>.json that defines the schema <name> counts as")
	out.outf("a schema file; pull never names or removes any other file.")
	out.outf("A schema whose name contains /, \\, .. or a leading dot is skipped and named.")
	out.outf("")
	out.outf("Fields are written as the server stores them. An older server cannot send")
	out.outf("them that way (array members lose their own fields, a named type comes as")
	out.outf("a copy); pull says so, and push then refuses a change to such a schema.")
	out.outf("")
	out.outf("flags:")
	out.outf("  --prune      also remove the schema files whose schema is not on the server")
	out.outf("  --dry-run    say what would be written and removed, and write nothing")
	out.outf("")
	out.outf("example:")
	out.outf("  bp schema pull ./schemas")
}

func printSchemaDiffHelp(out *writer) {
	out.outf("usage: bp schema diff <dir> [-o table|json|yaml]")
	out.outf("")
	out.outf("Compares the schema files in <dir> to the dataset's schemas and prints the")
	out.outf("plan a push would follow: added (in the folder only), changed (with the")
	out.outf("fields added, removed and changed, and the other keys that differ),")
	out.outf("removed (on the server only) and the count of unchanged schemas.")
	out.outf("")
	out.outf("Only the keys the server stores are compared. A top-level key the file")
	out.outf("leaves out counts as its default (kind document, an empty list or object;")
	out.outf("a file without visibility keeps the server's), and the keys the server adds to a field (required?,")
	out.outf("the of list of an array, the to list of a reference) are worked out the same")
	out.outf("way for both sides. Every other value must match exactly. Nothing is written.")
	out.outf("")
	out.outf("exit codes: 0 when there is no difference, 1 when there is one, 5 when a")
	out.outf("file in <dir> is not a schema definition. Use it as a CI check.")
	out.outf("")
	out.outf("example:")
	out.outf("  bp schema diff ./schemas -o json")
}

func printSchemaPushHelp(out *writer) {
	out.outf("usage: bp schema push <dir> [--prune] [--dry-run] [--yes] [-o table|json|yaml]")
	out.outf("")
	out.outf("Prints the same plan as `bp schema diff`, then applies the added and the")
	out.outf("changed schemas. Each <name>.json must define the schema <name>. A file")
	out.outf("that does not parse stops the push before anything is written. A key that")
	out.outf("a file leaves out is reset to its default on the server. The exception is")
	out.outf("visibility: a file that does not set it leaves a private schema private.")
	out.outf("")
	out.outf("Schemas that are on the server only are left alone unless you pass --prune.")
	out.outf("Until they are pruned or pulled, `bp schema diff` keeps exiting 1 for them.")
	out.outf("The server refuses to delete a schema that still has documents.")
	out.outf("")
	out.outf("flags:")
	out.outf("  --prune      also delete the server schemas that have no file in <dir>;")
	out.outf("               asks first, and needs --yes when it cannot ask")
	out.outf("  --dry-run    print the plan and write nothing")
	out.outf("  --yes        skip the production and the delete confirmation")
	out.outf("")
	out.outf("example:")
	out.outf("  bp schema push ./schemas --dry-run")
}

// parseSchemaSyncArgs reads `<dir> [--prune]`. allowPrune is false for diff.
func parseSchemaSyncArgs(tail []string, allowPrune bool) (dir string, prune bool, err error) {
	for _, a := range tail {
		switch {
		case a == "--prune" && allowPrune:
			prune = true
		case strings.HasPrefix(a, "-") && a != "-":
			return "", false, fmt.Errorf("unknown flag %s", a)
		case dir != "":
			return "", false, fmt.Errorf("expected one folder, got %s and %s", dir, a)
		default:
			dir = a
		}
	}
	if dir == "" {
		return "", false, fmt.Errorf("name the folder that holds the schema files")
	}
	return dir, prune, nil
}

func schemaSyncDataset(ctx manifest.Context) string {
	if ctx.Dataset == "" {
		return "production"
	}
	return ctx.Dataset
}

// loadSchemaPlan reads the folder and the server and compares them. It
// returns the plan, the folder's files, and an exit code that is exitOK only
// when all three steps worked.
func loadSchemaPlan(out *writer, ctx manifest.Context, verb, dir string) (*schemaPlan, map[string]json.RawMessage, int) {
	local, err := readSchemaDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil, useError(out, "usage", fmt.Sprintf("schema %s: %s is not a folder. Run `bp schema pull %s` to create it.", verb, dir, dir), exitUsage)
		}
		return nil, nil, useError(out, "validation_failed", fmt.Sprintf("schema %s: %v. Nothing was written.", verb, err), exitValidation)
	}
	server, stored, err := fetchSyncSchemas(ctx, schemaSyncDataset(ctx))
	if err != nil {
		return nil, nil, useError(out, "request_failed", fmt.Sprintf("schema %s: reading the schemas of %s: %v", verb, exportScope(ctx), err), exitGeneric)
	}
	plan, err := buildSchemaPlan(exportScope(ctx), dir, local, server, stored)
	if err != nil {
		return nil, nil, useError(out, "failed", fmt.Sprintf("schema %s: %v", verb, err), exitGeneric)
	}
	return plan, local, exitOK
}

// renderSchemaPlan prints the plan for a person. removedNote says what
// happens to the schemas that are on the server only.
func renderSchemaPlan(out *writer, p *schemaPlan, removedNote string) {
	out.outf("schemas in %s compared to %s:", p.Dir, p.Scope)
	for _, n := range p.Added {
		out.outf("  + %s  added (in the folder only)", n)
	}
	for _, c := range p.Changed {
		out.outf("  ~ %s  changed (%s)", c.Name, c.summary())
		if len(c.CutMembers) > 0 {
			out.outf("      push would replace the stored definition of: %s", strings.Join(c.CutMembers, ", "))
		}
	}
	for _, n := range p.Removed {
		out.outf("  - %s  %s", n, removedNote)
	}
	for _, n := range p.VisibilityKept {
		out.outf("  = %s  stays private: the file does not set visibility", n)
	}
	for _, n := range p.Skipped {
		out.outf("  ! %q  skipped: the name cannot be a file name", n)
	}
	out.outf("  %d added, %d changed, %d removed, %d unchanged", len(p.Added), len(p.Changed), len(p.Removed), p.Unchanged)
}

func schemaPlanPayload(p *schemaPlan) map[string]any {
	payload, _ := toGeneric(p).(map[string]any)
	payload["differences"] = p.differs()
	return payload
}

// runSchemaPull is `bp schema pull <dir> [--prune]`.
func runSchemaPull(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printSchemaPullHelp(out)
		return exitOK
	}
	dir, prune, err := parseSchemaSyncArgs(tail, true)
	if err != nil {
		return usageErrf(out, func() { printSchemaPullHelp(out) }, "schema pull: %v", err)
	}
	server, stored, err := fetchSyncSchemas(ctx, schemaSyncDataset(ctx))
	if err != nil {
		return useError(out, "request_failed", fmt.Sprintf("schema pull: reading the schemas of %s: %v", exportScope(ctx), err), exitGeneric)
	}
	// Decode every schema before the first write, so a schema that does not
	// parse leaves the folder as it was.
	files := map[string][]byte{}
	written, skipped := []string{}, []string{}
	for _, raw := range server {
		obj, err := decodeSchemaJSON(raw)
		if err != nil {
			return useError(out, "failed", fmt.Sprintf("schema pull: the server sent a schema that did not parse: %v. Nothing was written.", err), exitGeneric)
		}
		name, _ := obj["name"].(string)
		if !schemaFileNameOK(name) {
			skipped = append(skipped, name)
			continue
		}
		body, err := prettySchemaJSON(obj)
		if err != nil {
			return useError(out, "failed", fmt.Sprintf("schema pull: %v. Nothing was written.", err), exitGeneric)
		}
		files[name] = body
		written = append(written, name)
	}
	sort.Strings(written)
	sort.Strings(skipped)

	// A stale file is a regular <name>.json that defines schema <name> and has
	// no schema on the server. Any other file in the folder (package.json, a
	// symlink, a file that is not a schema) is never named or removed.
	stale := []string{}
	entries, err := os.ReadDir(dir)
	if err != nil && !os.IsNotExist(err) {
		return useError(out, "failed", fmt.Sprintf("schema pull: %v. Nothing was written.", err), exitGeneric)
	}
	for _, e := range entries {
		stem := strings.TrimSuffix(e.Name(), ".json")
		if !e.Type().IsRegular() || stem == e.Name() || files[stem] != nil {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		if obj, err := decodeSchemaJSON(raw); err == nil && obj["name"] == stem && schemaFileNameOK(stem) {
			stale = append(stale, stem)
		}
	}
	pruned := []string{}
	if prune {
		pruned, stale = stale, pruned
	}

	if !g.dryRun {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return useError(out, "failed", fmt.Sprintf("schema pull: %v", err), exitGeneric)
		}
		for _, name := range written {
			path := filepath.Join(dir, name+".json")
			err := os.WriteFile(path+exportPartialSuffix, files[name], 0o644)
			if err == nil {
				err = os.Rename(path+exportPartialSuffix, path)
			}
			if err != nil {
				return useError(out, "failed", fmt.Sprintf("schema pull: %v", err), exitGeneric)
			}
		}
		for _, name := range pruned {
			if err := os.Remove(filepath.Join(dir, name+".json")); err != nil {
				return useError(out, "failed", fmt.Sprintf("schema pull: %v", err), exitGeneric)
			}
		}
	}

	if out.emitStructured(map[string]any{"scope": exportScope(ctx), "dir": dir, "dry_run": g.dryRun, "stored_fields": stored, "written": written, "pruned": pruned, "stale": stale, "skipped": skipped}) {
		return exitOK
	}
	wrote, removed := "wrote", "removed"
	if g.dryRun {
		wrote, removed = "dry run: would write", "dry run: would remove"
	}
	out.outf("%s %d schema(s) of %s to %s", wrote, len(written), exportScope(ctx), dir)
	for _, n := range written {
		out.outf("  %s.json", n)
	}
	for _, n := range pruned {
		out.outf("%s %s.json: %s has no schema %s", removed, n, exportScope(ctx), n)
	}
	for _, n := range stale {
		out.outf("kept %s.json: %s has no schema %s. Pass --prune to remove the file.", n, exportScope(ctx), n)
	}
	for _, n := range skipped {
		out.outf("skipped schema %q: the name cannot be a file name", n)
	}
	if g.dryRun {
		out.outf("dry run: nothing was written")
	}
	if !stored {
		out.errf("note: %s", schemaServedNote)
	}
	return exitOK
}

// schemaServedNote is what pull and diff say on a server that cannot send
// stored fields.
const schemaServedNote = "this server cannot send fields as stored: the members of an array field come without their own fields, " +
	"and a field of a named type comes as a copy of that type. `bp schema push` will not apply a change to a schema with such fields until the server is updated."

// runSchemaDiff is `bp schema diff <dir>`.
func runSchemaDiff(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printSchemaDiffHelp(out)
		return exitOK
	}
	dir, _, err := parseSchemaSyncArgs(tail, false)
	if err != nil {
		return usageErrf(out, func() { printSchemaDiffHelp(out) }, "schema diff: %v", err)
	}
	plan, _, code := loadSchemaPlan(out, ctx, "diff", dir)
	if code != exitOK {
		return code
	}
	if !out.emitStructured(schemaPlanPayload(plan)) {
		renderSchemaPlan(out, plan, "removed (on the server only)")
	}
	if !plan.StoredFields {
		out.errf("note: %s", schemaServedNote)
	}
	if plan.differs() {
		return exitSchemaDiff
	}
	return exitOK
}

// runSchemaPush is `bp schema push <dir> [--prune]`.
func runSchemaPush(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printSchemaPushHelp(out)
		return exitOK
	}
	dir, prune, err := parseSchemaSyncArgs(tail, true)
	if err != nil {
		return usageErrf(out, func() { printSchemaPushHelp(out) }, "schema push: %v", err)
	}
	plan, local, code := loadSchemaPlan(out, ctx, "push", dir)
	if code != exitOK {
		return code
	}
	removedNote := "left alone (on the server only; --prune deletes it)"
	if prune {
		removedNote = "will be deleted (on the server only)"
	}
	if !out.machineOut() {
		renderSchemaPlan(out, plan, removedNote)
	}

	toApply := append([]string{}, plan.Added...)
	for _, c := range plan.Changed {
		toApply = append(toApply, c.Name)
	}
	sort.Strings(toApply)
	toDelete, leftAlone := []string{}, plan.Removed
	if prune {
		toDelete, leftAlone = plan.Removed, []string{}
	}
	result := schemaPlanPayload(plan)
	result["dry_run"] = g.dryRun
	result["applied"] = []string{}
	result["deleted"] = []string{}
	result["left_alone"] = leftAlone

	if g.dryRun || len(toApply)+len(toDelete) == 0 {
		if !out.emitStructured(result) {
			if g.dryRun {
				out.outf("dry run: nothing was written")
			} else {
				out.outf("nothing to push")
			}
		}
		return exitOK
	}

	// A server that cannot send stored fields has shown array members without
	// their own fields. Applying a file built from that would replace the
	// stored members, so the push stops before any write.
	var cut []string
	for _, c := range plan.Changed {
		if len(c.CutMembers) > 0 {
			cut = append(cut, fmt.Sprintf("%s (%s)", c.Name, strings.Join(c.CutMembers, ", ")))
		}
	}
	if len(cut) > 0 {
		return useError(out, "conflict", fmt.Sprintf("schema push: this server cannot send fields as stored, and the file has what it served instead, "+
			"so applying it would replace the stored definition of %s. Nothing was written. "+
			"Update the server so it can send stored fields, or write those fields out in the file as they should be stored.", strings.Join(cut, "; ")), exitConflict)
	}

	// Both confirmations come before the first write, so a refusal leaves
	// the server as it was.
	if isProd(ctx, &manifest.Manifest{}) && !g.yes && !serverDeclaredNonProd(ctx.Server) {
		if !confirmProdWrite(out, manifest.Command{Noun: "schema", Verb: "push"}, ctx) {
			out.errf("aborted: prod write not confirmed")
			return exitUsage
		}
	}
	if len(toDelete) > 0 && !confirmSchemaPrune(out, g, ctx, toDelete) {
		out.errf("aborted: nothing was written")
		return exitUsage
	}

	dataset := schemaSyncDataset(ctx)
	if len(toApply) > 0 {
		f := &schemaCopyFile{}
		for _, n := range toApply {
			body, err := schemaPushBody(local[n])
			if err != nil {
				return useError(out, "failed", fmt.Sprintf("schema push: %s: %v. Nothing was written.", n, err), exitGeneric)
			}
			f.Schemas = append(f.Schemas, body)
		}
		if err := applySchemas(out, ctx, dataset, f); err != nil {
			return useError(out, "request_failed", fmt.Sprintf("schema push: %v. No schema was deleted.", err), exitGeneric)
		}
		result["applied"] = toApply
	}
	for i, n := range toDelete {
		if err := deleteSchemaForPush(ctx, dataset, n); err != nil {
			return useError(out, "request_failed", fmt.Sprintf("schema push: applied %d schema(s) and deleted %d of %d, then stopped: %v", len(toApply), i, len(toDelete), err), exitGeneric)
		}
	}
	result["deleted"] = toDelete

	if !out.emitStructured(result) {
		out.outf("applied %d schema(s) to %s, deleted %d, left %d alone", len(toApply), plan.Scope, len(toDelete), len(leftAlone))
	}
	return exitOK
}

// confirmSchemaPrune is the delete confirmation of `bp schema push --prune`.
// `bp schema delete` is guarded by the production write confirm, which push
// has already passed. Prune deletes several schemas in one command, so it also
// follows destroy_confirm.go on every server: the plan above has named each
// schema, --yes proceeds, a terminal is asked, and anything else is refused.
func confirmSchemaPrune(out *writer, g globals, ctx manifest.Context, names []string) bool {
	if g.yes {
		return true
	}
	if !destroyStdinIsTTY(destroyStdin) {
		out.userErr("schema push --prune deletes %d schema(s) from %s (%s) and needs confirmation — re-run with --yes",
			len(names), exportScope(ctx), strings.Join(names, ", "))
		return false
	}
	fmt.Fprintf(out.stderr, "Delete %d schema(s) from %s (%s)? [y/N] ", len(names), exportScope(ctx), strings.Join(names, ", "))
	line, _ := bufio.NewReader(destroyStdin).ReadString('\n')
	answer := strings.TrimSpace(strings.ToLower(line))
	return answer == "y" || answer == "yes"
}

// deleteSchemaForPush deletes one schema, without force: the server refuses a
// schema that still has documents, and the error carries its message. The
// delete counts only when the receipt names the schema that was sent.
func deleteSchemaForPush(ctx manifest.Context, dataset, name string) error {
	u := ctxScopedURL(ctx, "/v1/schemas/"+url.PathEscape(dataset)+"/"+url.PathEscape(name))
	status, body, err := doRequest(http.MethodDelete, u, ctxAuthHeaders(ctx), nil)
	if err != nil {
		return fmt.Errorf("schema %s: %v", name, err)
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("schema %s: HTTP %d: %s", name, status, classifyError(status, body).errorMessage())
	}
	if serr := builtinWriteReceiptErr("schema delete", status, body); serr != nil {
		return fmt.Errorf("schema %s: %v", name, serr)
	}
	var receipt struct {
		Deleted string `json:"deleted"`
	}
	if json.Unmarshal(body, &receipt) != nil || receipt.Deleted != name {
		return fmt.Errorf("schema %s: the server answered %d but its receipt names schema %q", name, status, receipt.Deleted)
	}
	return nil
}
