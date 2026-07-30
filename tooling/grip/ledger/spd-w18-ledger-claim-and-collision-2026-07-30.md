# Re-derivation: SPD wave-18 ledger state, dedup collisions, and the …Rest/plugins 500 mechanism

Measured 2026-07-30 against the live `bp` server (guerrilla) and `origin/main`.
Verifier assignment `ledger-claim-and-collision`. No bp mutations were made (see
"Who writes" at the bottom).

## The three slice tasks: open and UNCLAIMED (published read, not a returned rev)

```sh
for t in spd-w17-browser-journey spd-w17-never-blank spd-w17-pending-honest \
         spd-w17-create-seam spd-w17-desk-operable \
         spd-b18-btn-focus-visible-desk-wide spd-b20-expanded-pane-focus-ring; do
  bp task get $t -o json | python3 -c "import json,sys;r=sys.stdin.read();d=json.loads(r[r.find('{'):]);x=d.get('doc',d);print(x['doc_id'],x['lifecycle_status'],x.get('criteria_progress'),x.get('assignee'),bool(x.get('claim')))"
done
# browser-journey open 0/11  assignee None  claim False
# never-blank     open 0/8   assignee None  claim False
# pending-honest  open 0/8   assignee None  claim False
```

## The four stale-open wave-17 tasks: their work DID merge (squash rewrote the SHAs)

The builder SHAs are NOT ancestors of main — that is squash-merge, not unmerged work.

```sh
for c in 920d563ee a0ce94ee3 e0f3eb240; do git merge-base --is-ancestor $c origin/main && echo A || echo NOT; done
# NOT NOT NOT      <- the loop-epic builder commits
gh pr view 7566 --json state,mergeCommit   # MERGED  c820cce8c   create-seam
gh pr view 7567 --json state,mergeCommit   # MERGED  6020b31a8   desk-operable
gh pr view 7568 --json state,mergeCommit   # MERGED  544eec20d   session-icon + sibling-schema-icons
for c in c820cce8c 6020b31a8 544eec20d; do git merge-base --is-ancestor $c origin/main && echo ANCESTOR; done
```

Remaining unmet criteria are only the lead-owned ones (`PR merged to main (LEAD
closes)`), plus create-seam's local-suite criterion that CI's `Elixir gate`
covered instead:

```sh
bp task get spd-w17-create-seam -o json | python3 -c "import json,sys;r=sys.stdin.read();d=json.loads(r[r.find('{'):]);x=d.get('doc',d);[print(a['met'],a['criterion'][:80]) for a in x['content']['acceptance_criteria']]"
```

## The focus-visible collision is FOUR-way and all four are in one file

```sh
git show origin/main:api/lib/barkpark_web/layouts/root.html.heex > /tmp/root.heex
grep -c focus-visible /tmp/root.heex                      # 43
grep -n focus-visible /tmp/root.heex | grep bp-desk-chip   # (none)
grep -n focus-visible /tmp/root.heex | grep bp-doc-checkbox # (none)
grep -n focus-visible /tmp/root.heex | grep -E '\.btn'      # (none)
grep -n focus-visible /tmp/root.heex | grep pane-column     # :1704 --collapsed, :1730 [tabindex="-1"]
grep -c bp-desk-chip /tmp/root.heex     # 3 rules exist, none :focus-visible
grep -c bp-doc-checkbox /tmp/root.heex  # 4 rules exist, none :focus-visible
```

Claimants: `spd-b18-btn-focus-visible-desk-wide` (open, unclaimed, 0/3, `files:
["api/lib/barkpark_web/layouts/root.html.heex"]`, `.btn` base class),
`spd-b20-expanded-pane-focus-ring` (open, assignee `cody-reviewer-w5`, 2/3,
claim epoch 3 EXPIRED 2026-07-20, `.pane-column:focus-visible`),
`spd-bl-desk-chips-claim-tab-semantics-they-lack` (open, unclaimed — its
description ends "no :focus-visible rule exists for .bp-desk-chip"),
`spd-bl-doc-checkbox-is-an-unfocusable-span` (open, unclaimed, `.bp-doc-checkbox`).

## Two of the six "newly discovered" items are ALREADY FILED — do not re-file

```sh
bp task get spd-bl-publish-wall-self-rescue -o json   # open, unclaimed, parent studio-space-priority-desk
# title: A hand-created paper cannot be published out of the draft state - the authoring wall refuses it four ways
# desc already carries: label_spine >=20 chars, tag string, strength 1-100, rationale >=20,
#   {:unknown_tag}, AND {:halted, "This paper has a title but no content yet"}
bp task get spd-bl-session-birth-template -o json     # open, unclaimed
# title: Session documents have no birth template, so a new session opens to a canvas with nothing in it
# desc: writer.ex:310 matches "paper" ONLY; blocks_type? whitelists ["paper","session"];
#   paper_block_mode true with ZERO canvas runs. "NAMED OUT OF SCOPE for Wave 17 by charter D221"
```

`spd-bl-publish-wall-self-rescue` = the publish-affordance triple AND the
block-0-heading hollow trap (one task, both). `spd-bl-session-birth-template` =
slice 2's "resolved, nothing renderable" second seam, and it resolves the
digest's contradiction (a) in favour of "reaches no empty branch".

## The …Rest / /studio/plugins 500: mechanism is nil, not an unknown string

```sh
git show origin/main:api/lib/barkpark_web/components/icons.ex | sed -n '224p;257,258p'
# @unknown_icon_policy if Mix.env() == :test, do: :raise, else: :warn
# def resolve_paths(name, policy \\ @unknown_icon_policy) when is_binary(name) do
git show origin/main:api/lib/barkpark_web/components/icons.ex | sed -n '289p'
# attr :name, :string, required: true
git show origin/main:api/lib/barkpark_web/live/studio/studio_live/components.ex | sed -n '1067,1068p;1106p'
# :1067  <%= if item.icon do %>                      <- :plugin_link branch GUARDS
# :1106  <:icon><.icon name={item.icon} size={16} /></:icon>   <- catch-all `_ ->` does NOT
git show origin/main:api/lib/barkpark_web/studio/pane_builder.ex | sed -n '285p;981p'
# :285  icon: node.icon || (schema && schema.icon)   <- guarded
# :981  icon: child.icon,                            <- list_items/2, NOT guarded
git show origin/main:api/lib/barkpark/structure.ex | sed -n '41p;254p;301,318p'
# :41   :icon,   in Node's defstruct -> default nil
# :254  %Node{id: "plugin-grp-#{name}", ... type: :list, items: nodes}   <- NO icon => nil
# :301  rest_child_node: orphaned branch emits %Node{...} with NO icon; schema branch
#       uses Map.get(schema, :icon) which is nil when the schema JSON omits it
```

Chain: a `:list` group node's children go through `list_items/2` (:981,
unguarded) into the catch-all render branch (:1106, unguarded) into
`resolve_paths(nil)`, which has **no clause for nil** (`when is_binary(name)`)
=> `FunctionClauseError` => 500. The `:warn` fallback that the module's
docstring promises ("a cosmetic glyph never crashes a page") only covers an
unknown *string*. In `MIX_ENV=test` the policy is `:raise`, so this is
**offline-assertable** — no browser needed for the guard.

Anonymous probes cannot see it (auth wall):

```sh
for p in /studio/plugins /studio/rest /studio; do curl -s -o /dev/null -w "$p %{http_code}\n" https://guerrilla.barkpark.cloud$p; done
# /studio/plugins 302   /studio/rest 302   /studio 302
```

## Fence hole is real

```sh
git ls-tree -r origin/main --name-only api/test/barkpark_web/studio/ | wc -l   # 20
# includes pane_builder_test.exs and pane_builder_plugin_items_test.exs — exactly
# where the nil-icon guard and slice 2's registry-derived enumeration belong,
# and the declared test fence names only api/test/barkpark_web/{live/studio,components}/**
```

## Collateral facts re-derived while here

```sh
git show origin/main:.claude/workflows/bp-studio-space-priority-charter.md | wc -l   # 2157
git grep -n '<:empty_state' origin/main -- api/lib api/test                          # 0 hits: declared, NEVER FILLED
git grep -n 'studio_editor_shell' origin/main -- api/lib/barkpark_web/live/studio/studio_live/components.ex  # :1287 (task text says :1283 — rotted by 4)
git grep -c aria-busy origin/main -- api/lib                                         # no output: zero
git grep -n 'phx-click-loading' origin/main -- api/lib/barkpark_web/layouts/root.html.heex  # :3784 opacity 0.6
git grep -n '@blocks_types' origin/main -- api/lib                                   # block_ops.ex:44 ["paper","session"]
git show origin/main:api/lib/barkpark_web/live/studio/studio_live/paper_canvas.ex | sed -n '323p;333,335p'  # Default TRUE; nil -> true
git show origin/main:api/test/barkpark_web/live/studio/studio_live_new_paper_journey_test.exs | wc -l  # 201
git show origin/main:api/test/barkpark_web/live/studio/studio_live_new_paper_journey_test.exs | grep -ciE 'playwright|chromium|cdp|page\.'  # 0
git ls-tree origin/main tooling/ | grep studio-journey                               # absent
gh api repos/FRIKKern/barkpark/branches/main/protection --jq '{contexts:.required_status_checks.contexts,admins:.enforce_admins.enabled}'
# {"admins":true,"contexts":["Elixir gate","PR references an active task"]}
```

## Who writes

This verifier is barred from bp mutations by its role contract, so nothing above
was stamped or filed. The stamp/file/absorb list is handed to Decide, which owns
task writes in this cycle. Re-read published state after every write; a returned
`rev` is not persistence.
