<!-- doc-tier: cold | canonical-for: none | budget: 900tok -->
# go-correctness: cloudclient TeamMembers/TeamInvitations inner-decode swallow

Verdict: **REAL-low** — FILE as a published go-correctness task (not a Build fix; the fix is a
render-contract design choice better filed). Human render path only; JSON/YAML path SAFE.

## Re-derivation (origin/main HEAD a6535504)

Line numbers drift every wave — anchor by grep, not line.

    # locate the two swallowed inner decodes
    git grep -n '_ = json.Unmarshal(env.Members' -- internal/cloudclient/client.go
    git grep -n '_ = json.Unmarshal(env.Invitations' -- internal/cloudclient/client.go
    # every caller across internal/ (non-test)
    git grep -n 'TeamMembers\|TeamInvitations' -- 'internal/**/*.go' | grep -v _test
    # gate (both exit 0 on origin/main)
    CC=/usr/bin/clang CGO_ENABLED=1 go vet ./internal/cloudclient/... && go build ./...

## The mechanism

`TeamMembers` (client.go func at ~2972): outer envelope decode IS error-checked
(`decode members response: %w`). Inner `_ = json.Unmarshal(env.Members, &members)` is swallowed;
`Raw: env.Members` preserved, `Members` left nil on failure. Same shape in `TeamInvitations`.

Sole caller: `internal/cli/cloud_members.go`.
- JSON/YAML path `emitMembersRaw` -> uses `m.Raw` (verbatim bytes, D4 contract) -> **SAFE**, decode
  outcome irrelevant.
- Human path `renderMembersResult` -> `if len(m.Members) == 0 { "(no members)" }` -> a non-empty but
  shape-mismatched array silently renders **"(no members)"**, indistinguishable from a genuine empty
  roster, with NO signal the decode failed. This is the wish's class-2 "error path returns a zero
  value a caller treats as valid."

## Concrete triggering 200 body (all TeamMember fields are strings)

    {"members":[{"email":42,"role":"admin"}]}

Outer decode OK (env.Members = valid RawMessage). Inner decode fails ("cannot unmarshal number into
Go struct field TeamMember.email of type string") -> swallowed -> members=nil -> human view prints
"(no members)" while a member exists. `-o json` emits the array verbatim -> correct.

Triggers only under server/client CONTRACT SHAPE SKEW (same-team control plane) — hence low severity:
no panic, no wrong machine output, JSON path safe.

## Suggested fix (for the filed task, not built here)

On inner-decode error with non-empty/non-`[]` Raw, render an honest note in the human path
(mirroring how `TeamInvitations`' non-nil `ierr` already degrades to "Could not read pending
invitations: <err>"). A table-driven test feeding the body above reds on origin/main (expects
"(no members)"), greens after (expects a "could not read" note).

## deliveries.go deliveriesError swallow — SAFE

`_ = json.Unmarshal(body, &env)` in `deliveriesError` is an ERROR-body best-effort parse with `Raw:
body` preserved; empty Code/Reason/Detail fall back to Raw. Standard error-degradation. SAFE.
