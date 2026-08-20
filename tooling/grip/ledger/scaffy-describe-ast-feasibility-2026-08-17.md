<!-- doc-tier: cold | canonical-for: scaffy-describe-ast-feasibility-recipe | budget: 400tok -->
# Re-derivation recipe — `bp scaffy describe -o json` is AST-only (plumbing-free)

Verdict: everything describe must emit is already on the parsed AST. `scaffy.Parse(filename, src) (*Command, []Finding)` (internal/scaffy/parse.go:13) returns the full tree; describe walks it, no parse-side work.

Re-derive the AST field coverage:

    grep -n 'OneOf\|Examples\|Opaque\|Shape\|Successor\|Title\|Description' internal/scaffy/ast.go

Expected: VariableDecl (ast.go:90-104) carries Opaque bool, Shape, Successor, OneOf []string, Title, Description, Examples []string. Ops []Op (ast.go:31) with concrete *CreateFile/*DeleteFile/*InOp; InOp.Verb is InOpVerb (String() at :231). Asserts []*Assert (ast.go:296) with Kind (String() at :278 → "ASSERT FILE CONTAINS" etc), Text, Tier ("" LOCAL or "ci").

Caveat: no explicit `Kind` field on VariableDecl — derive it from which fields are set (Opaque / Shape!="" / OneOf!=nil / Successor!="").

Verb-add tax baseline (run green before adding describe):

    CGO_ENABLED=0 go test ./internal/cli -run 'Completion' -v

(Bare `go test` FAILS on a clang-less/CC-broken host — cgo `error: unknown option '-E'`; CGO_ENABLED=0 is the correct baseline.) A new verb touches: internal/cli/scaffy_cmd.go (dispatch case + printScaffyDescribeHelp), printScaffyHelp usage line (scaffy_cmd.go:758), scaffy_cmd_test.go:384 golden help roster (+ a describe help row), and a describe unit test. Completion verbs are NOT baked from a static scaffy list (manifest-driven only; scaffy is a builtin noun at builtins.go:321) — no completion-roster edit needed for the verb.
