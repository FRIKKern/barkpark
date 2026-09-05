package cli

// THE TRAP THIS CLOSES (#18, task-7f06080cfd584194). `bp doc mutate` takes a
// raw mutation batch — `{"mutations":[{…}]}` — and NOTHING in `bp doc mutate
// --help` said what a member of that array may look like. The manifest gives
// the command two flags (--file, --quiet) and a one-line summary that names
// five ops in a parenthesis and describes none. A caller with a wrong shape got
//
//	400 malformed: request body is malformed
//
// (api/lib/barkpark/content/errors.ex:438) from the catch-all
// `defp apply_one(_, _, _), do: {:error, :malformed}` at
// api/lib/barkpark/content/mutations.ex:490 — one message for every one of the
// nine clauses above it, naming no field. The reported consequence: Gyldendal
// read the shapes out of mutations.ex to proceed. That is the bar this list
// exists to clear — a caller must never have to open the server source.
//
// DERIVATION, not invention. Every entry below is one `apply_one/3` clause head
// in api/lib/barkpark/content/mutations.ex, in source order:
//
//	:238  %{"create"            => attrs}
//	:266  %{"createOrReplace"   => attrs}
//	:292  %{"createIfNotExists" => attrs}
//	:309  %{"publish"           => %{"id" => id, "type" => type}}
//	:339  %{"unpublish"         => %{"id" => id, "type" => type}}
//	:344  %{"discardDraft"      => %{"id" => id, "type" => type}}
//	:349  %{"delete"            => %{"id" => id, "type" => type} = op}
//	:384  %{"replace"           => attrs}
//	:421  %{"patch" => %{"id" => id, "type" => type} = patch} when …
//	:458  %{"patch" => %{"id" => id, "type" => type, "set" => fields} = patch}
//	:490  _  → {:error, :malformed}
//
// `patch` has two clauses (the guarded operator form and the `set` form) and is
// ONE shape to a caller, so it appears once. The catch-all is not a shape.
// TestMutateHelpNamesEveryServerMutationClause (mutate_shapes_test.go) reads
// that file and reds if this list and those clause heads ever diverge in either
// direction — a new server op with no help entry, or a help entry naming an op
// the server would reject.
//
// This is HELP TEXT, not validation. The CLI does not pre-check a --file batch
// against these shapes: the server is the authority on what it accepts, and a
// client-side gate would be a second, drifting copy of the rule. The 422-that-
// names-the-missing-field half of #18 is a server change (mutations.ex /
// errors.ex) and is deliberately NOT attempted here.

// docMutateCommandID is the manifest id usage.go keys the shapes block on.
const docMutateCommandID = "doc.mutate"

// mutateShapeOps is the op-name half of the list, kept separate from the
// rendered lines so the drift test can compare NAMES against the server clause
// heads without parsing prose.
var mutateShapeOps = []string{
	"create",
	"createOrReplace",
	"createIfNotExists",
	"replace",
	"patch",
	"publish",
	"unpublish",
	"discardDraft",
	"delete",
}

// mutateShapeLines is the block `bp doc mutate --help` prints under
// "mutation shapes:". One line per op, each showing the JSON literally — a
// shape you can paste, not a description of one.
func mutateShapeLines() []string {
	return []string{
		"mutation shapes: --file takes {\"mutations\":[ … ]}; each element is exactly one of",
		`  {"create":            {"_type":"<type>", "_id":"<id>"?, …fields}}   _id auto-generated if omitted`,
		`  {"createOrReplace":   {"_type":"<type>", "_id":"<id>",  …fields}}   upsert; _id REQUIRED`,
		`  {"createIfNotExists": {"_type":"<type>", "_id":"<id>",  …fields}}   no-op if it exists; _id REQUIRED`,
		`  {"replace":           {"_type":"<type>", "_id":"<id>",  …fields}}   overwrites an EXISTING draft; 404 if none`,
		`  {"patch":   {"id":"<id>", "type":"<type>", "set":{…}}}              plus setIfMissing/unset/inc/dec/append/prepend`,
		`  {"publish": {"id":"<id>", "type":"<type>"}}                         id and type are BOTH required`,
		`  {"unpublish":    {"id":"<id>", "type":"<type>"}}                    id and type are BOTH required`,
		`  {"discardDraft": {"id":"<id>", "type":"<type>"}}                    id and type are BOTH required`,
		`  {"delete":       {"id":"<id>", "type":"<type>"}}                    id and type are BOTH required`,
		"  note: the create/replace family keys the document as _id/_type INSIDE the payload;",
		"        patch/publish/unpublish/discardDraft/delete take a bare id/type pair. A shape",
		"        that matches none of the above is a 400 `malformed: request body is malformed`,",
		"        which names no field — compare against this list first.",
		"  drafts: create/createOrReplace/createIfNotExists/replace/patch all write the `drafts.<id>`",
		"        twin. The published row does not move until {\"publish\":{\"id\",\"type\"}} runs",
		"        (or `bp doc publish <type> <id>`). bp prints which lens moved on every 2xx.",
	}
}
