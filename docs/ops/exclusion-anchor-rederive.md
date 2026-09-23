<!-- doc-tier: agent | canonical-for: exclusion-anchor-rederive | budget: 1200tok -->
# Re-deriving an exclusion anchor — the cross-fence ruling and the procedure

`scripts/pds-elixir-receipt-census.exs` carries `@exclusion_anchors`: a committed
register of `{anchor_mfa, clause_count, def_fp}` keyed on the quad
`@routed_excluded` uses. For the NARROW rows — actions whose names start
`delete`, `revoke`, `destroy` or `purge` — the census's `EXCLUSION-ANCHORS-FRESH`
arm **reds** when a committed `def_fp` no longer names the def it was committed
against.

`def_fp` is a fingerprint of the action's own clauses. **Any edit to the BODY of
one of those actions moves it**, `mix format` reflows included, even when the
change is otherwise entirely inside one lane's own files. The repair must land in
the same commit — a split leaves `main` red between two merges.

That is a real coupling between an `api/lib/barkpark_web/controllers/**` edit and
a `scripts/**` file. It is declared where a lane meets it: a comment directly
above each anchored `delete`/`revoke` def, the register's header comment, and the
`EXCLUSION-ANCHORS-FRESH` failure message.

## The ruling: the re-anchor is an allowed cross-fence edit

**The lane whose change moved the fingerprint edits `@exclusion_anchors` itself,
in the same commit.** The register is not routed through an owner lane and there
is no turnaround to wait for.

Why this side and not the other:

- The arm requires the repair in the **same commit**. An owner-lane route cannot
  deliver a same-commit edit without the owner authoring the causing lane's
  commit, so routing either degenerates into this ruling or ships the red.
- The edit carries **no judgement**. Three values are READ from a command's
  output. A wrong value reds the very gate that demanded the change, on the same
  PR, so the waiver cannot launder a mistake.

**Where the waiver stops.** It covers the three values of an EXISTING row and
nothing else. Adding a row, removing a row, changing a row's class, changing the
`@routed_excluded` table, or touching the arm itself is a census change and stays
with the census. If re-reading the class prose shows the DISPOSITION no longer
holds — the action now spells a literal `ok: true` receipt, or it no longer
belongs in `status_only_receipt` — that is not a mechanical re-anchor: stop, and
file it.

Never weaken, widen or delete the arm, and never move the register out of the
census to dodge the fence. A repair landing under a stale exclusion row is
exactly what the arm exists to catch.

## The procedure

1. Make your change to the controller action as normal.
2. Confirm the trip, reading the exit code directly (never pipe this script —
   `cmd | tail` reports tail's status):

       elixir scripts/pds-elixir-receipt-census.exs; echo "EXIT=$?"

   A trip is `EXIT=1` with `FAIL  EXCLUSION-ANCHORS-FRESH` naming your route and
   `def_fp moved <old> -> <new>`.
3. Emit the new values. **This command's STDOUT is the only source for them —
   never type a number out of the FAIL line or a CI log:**

       elixir scripts/pds-elixir-receipt-census.exs --exclusion-keys

   STDOUT is TSV, one line per `@routed_excluded` row:
   `method`, `path`, `module`, `action`, `anchor_mfa`, `clause_count`, `def_fp`,
   `file`. The one-line summary goes to STDERR, so `cut` and `wc -l` mean what
   they say.
4. Copy `anchor_mfa`, `clause_count` and `def_fp` from the row whose first four
   fields match the quad in the FAIL line into that row's `@exclusion_anchors`
   value. Re-read the class prose above the table against the def it now names.
5. Re-run step 2. `EXIT=0` and `PASS  EXCLUSION-ANCHORS-FRESH`.
6. Commit the controller change and the register edit **together**.

A multi-clause action folds its per-clause fingerprints in LINE ORDER, so an edit
to the second clause moves the value too. Step 3 already accounts for that.

## Keeping the def-site warnings in step (a known hand-maintained edge)

The comments are maintained by hand, so a NARROW row added later starts with no
warning above its def. Both sides are one command each — the register's view:

    elixir scripts/pds-elixir-receipt-census.exs --exclusion-keys \
      | awk -F'\t' '$4 ~ /^:(delete|revoke|destroy|purge)/ && $6 > 0 {print $8"\t"$4}' | sort -u

and the comments actually planted:

    grep -rln 'ANCHORED DELETE/REVOKE ROW' api/lib/barkpark_web/controllers

A new NARROW row owes its def the same comment block in the commit that adds it.
Adding one moves no fingerprint: a comment is not part of the def AST the census
folds, which is why this whole warning set landed without a single re-anchor.
