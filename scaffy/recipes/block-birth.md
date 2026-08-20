<!-- doc-tier: human | canonical-for: scaffy-recipe-block-birth | budget: none -->
# Recipe: block-birth — a new PortableDoc block type, engine-scaffolded then grown

The proven sequence for adding one block type across every surface. The scaffold is one
engine run (~9ms, parity at birth on all three code surfaces + the golden harness); the
grow phase is where the block's real rendering lives. Measured precedent: diff+filetree
were born exactly this way (grow 426s Go / 952s web per block); the recipe exists so no
builder rediscovers the sequence (recipe-told arms measure ~½ the cost of catalog-told —
`/papers/scaffy-loop-bench-status`).

## 0. Read the live pins first (never the corpus examples)

The command's `CountBefore/After` + `ParityCountBefore/After` are OPAQUE pairs YOU read
from the tree at run time — the `.scaffy` EXAMPLES are generations stale by design:

```sh
grep -o 'toHaveLength([0-9]*)' js/packages/react/tests/PortableDoc.test.tsx   # → CountBefore
grep -o 'EXPECTED_COUNT=[0-9]*' scripts/pd-parity-completeness.sh             # → ParityCountBefore
```

The two pins move independently — read both, never assume they match.

## 1. Scaffold (engine, all six count-sync sites asserted)

```sh
bp scaffy run scaffy/commands/add-block-type.scaffy \
  --var BlockName=Timeline \
  --var CountBefore=<read> --var CountAfter=<read+1> \
  --var ParityCountBefore=<read> --var ParityCountAfter=<read+1>
```

Dry-run note: `--dry-run` reports `ok:false` structurally (the 2 golden EXISTS asserts
fail pre-run by design) — documented, not a defect.

## 2. Grow the renderers (the real work — starter form → the block's actual contract)

Design the attrs contract first (one honest shape, Attrs-contract style), then grow in
this order, testing per surface as you go:

1. **Go** `internal/pdrender/<block_name>.go` + named test — width-aware, color never
   load-bearing, empty-input renders nothing (silent).
2. **React** emitter in `js/packages/react` + the CASES fixture — byte-parity with the
   Elixir compose output is the bar.
3. **Elixir** `compose_block/2` clause — before the catch-all; then REGENERATE the
   parity goldens (the command's own asserts run `gen_pd_parity` + completeness — the
   golden must be regenerated AGAIN after any post-scaffold grow, or it pins the starter).
4. **Tier**: run `bp scaffy run scaffy/commands/classify-block-type.scaffy` next —
   always (element/widget/section in tiers.ex; new viz/structure blocks are `:widget`).
5. **toPlainText**: classify the type in the typekeyed partition (PROSE vs TEXTLESS_SKIP —
   textless at birth is honest; growing prose later moves it, by hand).

## 3. Gates (the command asserts most of these; a red left red = NOT working)

```sh
CC=clang go build ./... && CC=clang go vet ./internal/pdrender/... \
  && CC=clang go test ./internal/pdrender/... -count=1
cd js && pnpm --filter @barkpark/core build && pnpm --filter @barkpark/react build \
  && cd packages/react && npx tsc --noEmit && npx vitest run
bash scripts/pd-parity-completeness.sh
make cloud-templates-sync   # then the drift test must be clean
node scripts/gen-showcase-content.mjs  # showcase seed pins (site 4)
```

## 4. What stays yours

- The block's attrs contract and its real rendering (the scaffold ships a starter).
- Email render posture (real render vs degrade badge) if the block reaches email.
- Studio canvas editability is SEPARATE work (~514 lines/8 files; backlog-priced) —
  view-only at birth is the shipped bar; E-grade honestly (E0–E4).

## 5. Reversal

`bp scaffy remove` the receipt — files, injections, and empty dirs all come back out
byte-clean. Post-grow removal will drift-refuse on grown files: that refusal is correct
(the block is no longer the scaffold; retire it deliberately, not mechanically).

## Laws this recipe encodes

- Live pins over corpus examples (transcription drift is the failure the pins prevent).
- Golden regen after EVERY grow, not just at scaffold.
- classify-block-type ALWAYS follows add-block-type.
- One block per receipt; batch blocks sequentially in one worktree, one PR per batch —
  the count pins are shared state and parallel PRs collide on them.
