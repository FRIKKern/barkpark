<!-- doc-tier: agent | canonical-for: paper-corpus-layers | budget: 1100tok -->

# Paper corpus layers — "uncited" is not a defect signal

The Paper corpus has **two layers with different rules**. Treating it as one
produces a phantom defect: a graph audit finds ~44% of papers cited by no task,
reads that as orphaned work, and proposes a cleanup that has nothing to clean.

* **Active layer** — papers a task points at, plus papers reachable from live
  work. Plans, charters and specs attached to work that is still open.
* **Archival layer** — changelog series, wave logs, closed-out rulings,
  superseded notes, audit verdicts. Uncited **by design**. A ruling paper's job
  is to be a verdict, not to spawn tasks.

Before filing anything about "orphaned papers", establish which layer you are in.

## The four citation channels

A task points at a paper through **four** keys, not three. A census that
enumerates three is already wrong.

| key | declared as | edge kind |
|---|---|---|
| `design_doc` | `reference` to paper | `design_doc` |
| `papers` | `array`, projected by the tasks plugin | `papers` |
| `wave_paper` | undeclared, projected by the tasks plugin | `wave_paper` |
| `parent_id` | `reference` to **task** | `parent_id` / `parent` |

`parent_id` is the one that gets missed: some papers are used as **epic anchors**
that tasks hang off, so a paper with no `design_doc` / `papers` / `wave_paper`
citation can still be the parent of dozens of tasks.

## How to tell the layers apart, mechanically

1. **Reachability from live work is the real test** — not "does it have a
   backlink". Walk inbound edges to their sources, then ask whether any source
   is cited by a task whose `lifecycle_status` is not `done` / `cancelled`. A
   paper linked only by papers that are themselves uncited is archival however
   many backlinks it carries.
2. **Closed-cluster signature.** Archival papers cite each other and nothing
   else. If every inbound source is itself uncited, you are inside the archive.
3. **Series shape.** Dated siblings under one stem (`…-2026-04-11`, `-12`, `-13`)
   are a log series and cross-reference within the series by construction.

## Measurement — 2026-08-24 (a measurement, NOT a standing fact)

Live corpus, published perspective. **This ratio drifts. Re-derive it; do not
quote it as current.**

```
published papers                                  1015
published tasks                                   7249
papers cited by >=1 task (all four channels)       568
papers cited by NO task                            447
  reachable from LIVE work                           9
  reachable only from dead/orphan sources          162   (161 cited only by uncited papers)
  never named by any other paper                   211
```

Method: census of all 451 three-key-uncited papers via `bp doc backlinks`
(0 failures); census of all 176 inbound-bearing papers for their sources
(0 failures); all 1015 bodies pulled for link analysis.

**The headline: only 9 of 447 uncited papers are reachable from live work.** The
remaining ~438 are the archival layer. That is the disposition, not a backlog.

## What inflates the count, and is a real bug

`Bulldocs.href_target/1` matches only a **root-relative** `/papers/<slug>` href.
A paper link written as an **absolute** URL to the instance's own host produces
no edge. Measured: 824 root-relative pairs become edges; 60 absolute pairs do
not, leaving 14 papers reporting zero backlinks while a published paper links
them. Every one is a `"type": "action"` (bp-button) block. Tracked as
`task-8172c629255adb3e` — **fix it before running any paper edge backfill**, or
the sweep re-projects the corpus and drops the same 60 links again.

Also live: the task parent relationship is projected twice, once as kind
`parent_id` (schema) and once as kind `parent` (tasks plugin) —
`task-724f2e93dff199f9`.

## Do not conclude

* **"Uncited" is not "orphaned".** Check the layer first.
* **"Has a backlink" is not "useful".** A backlink is a channel, not proof of
  live use.
* **Zero backlinks is not "nothing links it".** Body-walk projection is
  save-event-driven, and the absolute-URL bug above drops real links.
* **A prose `/papers/<slug>` in running text is not a citation** and is owed no
  edge. Match link nodes, never text.
