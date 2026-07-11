package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// mcp_bridge.go — the generic capabilities→MCP bridge (charter decisions 7,8):
// the manifest IS the MCP server. registerBridgeTools walks every manifest
// Command and, under `--tools all`, exposes each as one MCP tool named
// bp_<noun>_<verb> whose inputSchema is auto-derived from the command's Args and
// Flags. A tool's handler translates the MCP arguments object back into the CLI
// positional+flag tail and hands it to execManifestCommand (run.go, the same
// dispatch seam the curated task tools ride) — so ArgLocation inference
// (path/query/body), --set typing, MutationOp/SetKey wrapping, auth, and body
// serialization all ride the EXISTING run.go builder unchanged. The bridge
// re-implements none of that; it only shapes tool metadata and rebuilds the
// tail. Results follow charter decision 9: the raw response JSON as one text
// content block, IsError on HTTP >= 400 (mcpRun, mcp_tasks.go).
//
// Opt-in rationale: Cursor hard-caps 40 MCP tools across ALL enabled servers and
// silently drops the excess, while a live guerrilla manifest is ~107 commands.
// So `--tools all` is deliberate, and the curated eight (mcp_tasks.go) stay the
// default. Where the curated overlay already covers a command, the bridge
// SHADOWS its twin (see bridgeShadowedIDs) so the same capability is not exposed
// twice under two names.

// bridgeShadowedIDs is the set of manifest command IDs the curated overlay
// (mcp_tasks.go) already exposes under a hand-tuned name, so the bridge must NOT
// also generate a bp_<noun>_<verb> twin for them. The seven queue/read/close/
// prime/stamp/pulse verbs the curated eight cover are shadowed:
//
//   - task.ready  → curated task_ready
//   - task.next   → curated task_next  (atomic queue-claim)
//   - task.get    → curated task_show
//   - task.close  → curated task_close (epoch-CAS)
//   - task.prime  → curated task_prime (one-call rehydration)
//   - task.stamp  → curated task_stamp (mid-claim criterion evidence)
//   - task.pulse  → curated task_pulse (now-line + lease renewal)
//
// task.claim is NOT shadowed: the curated task_next is the ATOMIC queue-claim,
// whereas task.claim claims a SPECIFIC id — a distinct capability, so
// bp_task_claim generates. doc.create is likewise not covered by the curated
// eight and generates as bp_doc_create. (task_create has no manifest verb at all,
// so there is no twin to shadow.)
//
// This set is kept here next to the bridge because the bridge is what consults
// it; it is the single source of truth the curated registration in mcp_tasks.go
// must stay in sync with (charter: keep the shadowed-ID set adjacent to curated
// registration so the two never drift).
//
// MCP access parity = `--tools all`. The airdrop-grants `access` verbs
// (access.grant/ls/show/revoke/claim/mine) are NOT curated and are NOT shadowed
// here, so the bridge generates bp_access_grant/ls/show/revoke/claim/mine as
// soon as the manifest carries them — full grant-lifecycle parity over MCP under
// `bp mcp serve --tools all`. The DEFAULT `--tools tasks` toolset is curated by
// design (Cursor hard-caps 40 MCP tools), so the default surface omitting the
// access tools is intentional, not a gap. TestBridgeAccessParity pins both facts
// so a future shadow-set edit or verb rename reds the guard.
var bridgeShadowedIDs = map[string]bool{
	"task.ready": true,
	"task.next":  true,
	"task.get":   true,
	"task.close": true,
	"task.prime": true,
	"task.stamp": true,
	"task.pulse": true,
}

// registerBridgeTools walks m.Commands and registers one MCP tool per command
// (skipping the curated-shadowed IDs) on srv. It is the whole of the
// `--tools all` surface: pure over the manifest, so a new plugin command becomes
// an MCP tool with zero code change here. g and ctx are captured by each tool's
// handler and forwarded to execManifestCommand at call time.
func registerBridgeTools(srv *mcp.Server, g globals, ctx manifest.Context, m *manifest.Manifest) error {
	for i := range m.Commands {
		cmd := m.Commands[i] // capture by value per iteration for the closure
		if bridgeShadowedIDs[cmd.ID] {
			continue
		}
		schema, err := json.Marshal(bridgeInputSchema(cmd))
		if err != nil {
			return fmt.Errorf("derive schema for %s: %w", cmd.ID, err)
		}
		srv.AddTool(&mcp.Tool{
			Name:        bridgeToolName(cmd),
			Description: cmd.Summary,
			InputSchema: json.RawMessage(schema),
			Annotations: bridgeAnnotations(cmd),
		}, func(c context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			var args map[string]any
			if err := decodeMCPArgs(req, &args); err != nil {
				return mcpArgError(err), nil
			}
			tail := buildCommandTail(cmd, args)
			return mcpRun(execManifestCommand(g, ctx, m, cmd, tail)), nil
		})
	}
	return nil
}

// bridgeAnnotations derives the MCP behaviour hints for a generated tool
// straight from the manifest's cmd.Writes bit — the one honest signal the bridge
// already sees. A non-writing command is ReadOnlyHint:true (safe to call for
// information; the SDK marshals readOnlyHint only when true, so read tools carry
// the positive hint). A writing command is ReadOnlyHint:false + DestructiveHint
// explicitly true: the manifest cannot tell an additive create from a
// destructive update, so the conservative hint is "may modify" — a client that
// gates on destructiveHint then prompts before the call. IdempotentHint and
// OpenWorldHint are left unset: the manifest carries no signal for either, and a
// wrong hint is worse than an absent one (both default sensibly SDK-side).
func bridgeAnnotations(cmd manifest.Command) *mcp.ToolAnnotations {
	if cmd.Writes {
		return &mcp.ToolAnnotations{ReadOnlyHint: false, DestructiveHint: mcpBoolPtr(true)}
	}
	return &mcp.ToolAnnotations{ReadOnlyHint: true}
}

// bridgeToolName renders the MCP tool name for a command: bp_<noun>_<verb> with
// any character outside [A-Za-z0-9_] folded to '_' so a hyphenated noun like
// "ticket-key" yields a valid tool name (bp_ticket_key_mint) — MCP clients key
// tools by this string and the safe common denominator is underscores, matching
// the curated task_* names.
func bridgeToolName(cmd manifest.Command) string {
	return "bp_" + sanitizeToolSegment(cmd.Noun) + "_" + sanitizeToolSegment(cmd.Verb)
}

func sanitizeToolSegment(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	return b.String()
}

// bridgeInputSchema derives a JSON Schema 2020-12 object from a command's Args
// and Flags. One property per Arg (required iff Arg.Required) and per Flag
// (never required — flags are optional by definition); the property description
// is the Arg/Flag Summary. Type mapping mirrors the charter: manifest "int" →
// "integer", everything else → "string"; a repeatable flag → an array of
// strings. Placement (path/query/body) is intentionally NOT encoded — that is
// runtime inference the run.go builder owns; the schema only names inputs.
func bridgeInputSchema(cmd manifest.Command) map[string]any {
	properties := map[string]any{}
	var required []string

	for _, a := range cmd.Args {
		properties[a.Name] = scalarProperty(a.Type, a.Summary)
		if a.Required {
			required = append(required, a.Name)
		}
	}
	for _, f := range cmd.Flags {
		if f.Repeatable {
			properties[f.Name] = map[string]any{
				"type":        "array",
				"items":       map[string]any{"type": "string"},
				"description": f.Summary,
			}
			continue
		}
		properties[f.Name] = scalarProperty(f.Type, f.Summary)
		// Flags are never required.
	}

	schema := map[string]any{
		"$schema":    "https://json-schema.org/draft/2020-12/schema",
		"type":       "object",
		"properties": properties,
	}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}

// scalarProperty renders a single non-repeatable property: manifest "int" →
// integer, everything else (string/slug/file/bool/…) → string, with the summary
// as the description.
func scalarProperty(manifestType, summary string) map[string]any {
	jsonType := "string"
	if manifestType == "int" {
		jsonType = "integer"
	}
	prop := map[string]any{"type": jsonType}
	if summary != "" {
		prop["description"] = summary
	}
	return prop
}

// buildCommandTail reconstructs the CLI positional+flag tail from an MCP
// arguments object, exactly as a human would type it — so execManifestCommand
// (which drives the same run.go path splitArgs/bindArgs/BuildURL/applyQuery/
// buildBody use) places each value in path, query, or body identically to CLI
// dispatch. Positionals are emitted in Args order; an omitted optional arg that
// precedes a provided one is filled with "" so positional binding stays aligned
// (buildBody/applyQuery skip empty values, so the placeholder is inert).
// Non-string scalars are stringified with fmt.Sprint (observed_epoch already
// rides the wire as a string; the server coerces via fetch_int). Flags follow:
// a bool flag emits a bare --name when truthy (never a value — splitArgs rejects
// an inline value on a bool); a repeatable flag repeats --name per array
// element; every other flag emits --name <value>.
func buildCommandTail(cmd manifest.Command, args map[string]any) []string {
	tail := []string{}

	// Positionals: emit up to the highest-index arg the caller actually supplied,
	// filling gaps with "" so binding stays positionally aligned.
	last := -1
	for i, a := range cmd.Args {
		if _, ok := args[a.Name]; ok {
			last = i
		}
	}
	for i := 0; i <= last; i++ {
		if v, ok := args[cmd.Args[i].Name]; ok {
			tail = append(tail, stringifyArg(v))
		} else {
			tail = append(tail, "")
		}
	}

	// Flags, in manifest order for deterministic output.
	for _, f := range cmd.Flags {
		v, ok := args[f.Name]
		if !ok {
			continue
		}
		if f.Type == "bool" {
			if isTruthy(v) {
				tail = append(tail, "--"+f.Name)
			}
			continue
		}
		if f.Repeatable {
			for _, elem := range asSlice(v) {
				tail = append(tail, "--"+f.Name, stringifyArg(elem))
			}
			continue
		}
		tail = append(tail, "--"+f.Name, stringifyArg(v))
	}
	return tail
}

// stringifyArg renders an MCP JSON scalar as the CLI token the manifest builder
// expects. Strings pass through verbatim; every other scalar (JSON number, bool)
// is fmt.Sprint'd — matching how the CLI already carries e.g. observed_epoch as
// a string the server coerces.
func stringifyArg(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprint(v)
}

// asSlice normalises a repeatable-flag value into a slice: a JSON array is
// spread element-per-element; a lone scalar is wrapped so a client that passes a
// single value instead of a one-element array still works.
func asSlice(v any) []any {
	if arr, ok := v.([]any); ok {
		return arr
	}
	return []any{v}
}

// isTruthy decides whether a bool-flag value should emit its --name. A real JSON
// bool is honoured directly; a stringified "true"/"1" (a client that sent the
// string form of the string-typed schema) also counts.
func isTruthy(v any) bool {
	switch t := v.(type) {
	case bool:
		return t
	case string:
		return t == "true" || t == "1"
	default:
		return false
	}
}
