# truth-grip wave 10 — the 45 parks re-adjudicated, and the field the reason was written to

doc-tier: grip-ledger | topic: tgw10-park-reason-durability | derived: 2026-09-02

Companion to `tgw9-s4-tail-disposition-2026-07-27.recipe.md` §R7, which recorded that the wave-10
park reasons did not persist and filed the re-adjudication as `tgw10-bl-park-reasons-not-durable`.
This row records the re-adjudication and **corrects §R7's control**, which named the wrong field.
Append-only commons (D118): a new file, no existing row opened.

## C1 — §R7's control names a field that CANNOT hold a park reason

§R7 reads:

```
bp task stage tgw2-bl-throw-liveness-observation considering --object research \
  --worker wave10-reviewer --note "…" --yes
bp task get tgw2-bl-throw-liveness-observation -o json   # content.engagement.note is there, verbatim
```

**That comment is false, and it is why the reasons "evaporated".** `bp task stage --note` writes to
the DURABLE `content.disposition_reason`. `content.engagement` is an EPHEMERAL lease
(`{object,holder,ts,lapse_ttl_seconds,lapses_at}`) that the TtlSweeper deletes wholesale after
~900s, and a note does not ride it. So a park reason written expecting `engagement.note` cannot
persist **by construction** — no sweep, no race, no operator error. Re-derived 2026-09-02 against
the live row on that same id: `content.disposition_reason` holds the note in full while
`content.engagement.note` is `null`.

- rerun: `bp task stage --help` — the `--note` flag text states "Written to the DURABLE
  content.disposition_reason — NOT to the engagement lease, which the TTL sweeper deletes after ~900s."

The original measurement in §R7 (0 of 46 rows carrying `content.engagement.note`) was correct as an
observation and wrong as a diagnosis: it read a field nothing ever writes. **A count of zero on a
field no writer targets is a pass-shaped absence, not a finding** — the same class this epic exists
to kill, one level inside its own correction.

## C2 — the gap re-derived at the 2026-09-02 denominator, on every durable key

Enumerate `lifecycle_status == "considering"` children of `truth-grip-epic` from
`bp task get truth-grip-epic -o json` `.children`, then `bp task get <id> -o json` on each:

| key | before (40 rows) | after (same 40 ids) |
|---|---|---|
| `content.disposition_reason` non-empty | 0 | 40 |
| `content.disposition` present | 0 | 40 |
| `content.reopen_trigger` non-empty | 0 | 36 |
| `content.engagement.note` non-empty | 0 | 0 (permanently — see C1) |

`reopen_trigger` is 36, not 40, because 4 rows were re-opened rather than re-parked and a trigger is
only meaningful on a park. The epic's considering set moves 40 → 36; children stay 164.

## C3 — where the 39 unrecoverable reasons actually came from

§R7 says 44 of 45 justifications "exist nowhere durable", and that is true of the **adjudication
fields**. It is not true of the rows. Re-reading all 40 descriptions in full: every one carries a
filer-written deferral clause in its own `description` — "NOT taken this wave", "deferred", "needs a
charter amendment", "MEASURE FIRST", "blocked on a collision", or a named unbuilt dependency. The
reasoning was durable all along, in prose, in the wrong place for a program to find it.

**The lesson is narrower and more useful than "the mechanism was not used":** the disposition was
written where a program looks and the reason where only a reader looks. Re-adjudication was
therefore mining, not invention — no reason below was authored from nothing.

## C4 — the bar applied, and the 4 rows that failed it

A park is justified when the row's own durable text names a **blocker**: a ruling owed, an unbuilt
dependency, a missing measurement, an explicit deliberate deferral, or a live collision. A measured
defect with a concrete fix and no live blocker is **not** a park. 36 of 40 cleared it. Four did not,
and were staged back to `open` with the reason recorded:

| row | why the park failed the bar |
|---|---|
| `tgw6-screen-provenance-and-entry-guard` | Only recorded reason is a wave-6 slice FENCE that has expired; the row states the fix is one line. |
| `tgw9-bl-trial-leads-worktree-exclude` | No blocker recorded. One-line exclude-list fix; measured live cost 38:30 vs 9s isolated. |
| `tgw9-bl-prescreen-adjudicate-disagree` | No blocker recorded. Two live gates rule oppositely on one command. |
| `tgw9-bl-epic-cycle-digest-demotion-prose` | Park reason EXPIRED and the row says so: its blocker PR #6086 merged (in-row correction 2026-08-23), so its own stated trigger has fired. |

The fourth is the shape worth keeping: **a park with a named trigger tells you when it has expired.**
A park without one cannot, which is the whole argument for `--reopen-trigger` being mandatory.

## C5 — the write contract used, and the persistence proof

```
bp task stage <id> considering --object research --worker cli2-w9 \
  --disposition parked --note "<reason>. REACTIVATE when: <trigger>" --reopen-trigger "<trigger>" --yes
bp task stage <id> open --worker cli2-w9 --disposition open --note "<why the park failed the bar>" --yes
```

40 writes, all landed first attempt, zero 5xx. **Persistence was proven by state re-read, never by
exit code** — every row re-fetched with `bp task get <id> -o json` after the write, and the
before/after table in C2 counted from those re-reads. `--disposition parked` is refused (422
`missing_reopen_trigger`) when neither the stage nor the row carries a trigger, so the park half of
this contract cannot regress to a reasonless park.

- rerun: `git grep -n 'REACTIVATE when' origin/main -- tooling/grip/ledger/tgw10-park-reasons-readjudicated-2026-09-02.md`
