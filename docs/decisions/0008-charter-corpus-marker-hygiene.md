<!-- doc-tier: agent | canonical-for: charter-corpus-marker-hygiene | budget: 1400tok -->
# 0008 — Six infrastructure markers in the tracked corpus: scrub-forward, redact one

**Status:** accepted, 2026-09-16. **Venue:** this file — the durable ruling the
merge carries for `ecd-bl-charter-corpus-hygiene`.
**Guard:** `scripts/charter-corpus-hygiene-check.sh` (wired into `doc-gates.yml`).

## The finding

Six literals are spread across **346 tracked files**: three IPv4 host addresses
(the pull-deployed CMS box and the two Cloud boxes), two email addresses, and the ssh key
filename `barkpark_indx`. Distribution: `tooling/` 227, `scripts/` 33,
`internal/` 16, `.claude/` 15, `.omx/` 10, everything else in single digits.

The row's title calls this "prod IPs and a customer email on a public repo".
Two corrections the evidence forces:

1. **There is no customer email.** The `gyldendal.no` address is the repo
   owner's own former work identity — `.claude/workflows/bp-cloud-gui-remake-charter.md`
   lists it beside two others as "(owner)", and `tooling/jarl-corpus-surveys/wave-a.json`
   records it under `frikk_identities` as a **git commit author** with 179
   commits, i.e. already published in every repo it committed to. It is the
   owner's address at a third-party *organisation*, not a third party's data.
2. **"92+ charters" understates it by 3.7x.** The real union is 346 files.

## The ruling: scrub-forward, plus one redaction

**A blanket rewrite of all 346 is refused.** Most of the corpus is *recorded
evidence* — `tooling/grip/ledger/**` is a documented append-only commons of
dated, immutable rows, `scripts/measurements/**` are captured runs, and
`docs/ops/studio-nav-bug-2026-04-19.md` is already classified "path-frozen
history" by `scripts/docs-anchors-check.sh`. So are the charters themselves:
`.claude/workflows/*-charter.md` are append-only ruling logs whose D- and
GR- entries quote measurements taken *on the named box*. Rewriting an address
inside such a row makes a past measurement say something it did not say. That
is a worse defect than the exposure, and it is why c0 offers three options
rather than one.

**REDACT-WORST (done in this merge).** The `gyldendal.no` address is removed
from all 4 files that carried it (6 occurrences), replaced by
`<redacted-email>`, which preserves each sentence's meaning. It is the one
marker naming a third-party organisation's domain, it is the cheapest to lose,
and its removal takes the repo to a **zero baseline** — which is what makes it
mechanically enforceable with no exclusion list at all. The two JSON evidence
files carry a *visible* redaction token rather than a silent substitution, so
the record shows that a redaction happened.

**SCRUB-FORWARD (enforced from here).** No NEW charter may introduce any of the
six markers. The guard grandfathers the existing charter set **by predicate** —
the files present at the baseline commit, computed at runtime from
`git ls-tree` — not by a hand-maintained list, so it cannot rot behind the
corpus.

## The cost, stated

**What stays exposed, deliberately:** the three IPv4 addresses and the
`guerrilla.no` address remain in ~342 files, and `barkpark_indx` remains
everywhere. Judged acceptable because: they are the operator's *own*
infrastructure and the repo owner's *own* public contact address; they have been
in a public repo for months, so removal from `HEAD` recovers nothing already
lost; `barkpark_indx` is a **filename**, not a key — no private material is in
the tree; and the ops runbooks need runnable literals (`ssh root@<ip>`), a
position this repo already ruled on in the prod-host `tripwire` allowlist
in `scripts/docs-anchors-check.sh`. Replacing those with placeholders would
break the canonical runbook to buy nothing.

**Not decided here — OWNER item.** Whether to rewrite git history to purge the
markers from past commits is **out of scope for this merge** and is not settled
by this ruling. It is a destructive, coordination-heavy operation on a public
repo with many concurrent worktrees, and it belongs to the repo owner alone.
This change is forward-only.

**Also for the owner:** the same charter line that names the `gyldendal.no`
address also names two further personal addresses on the `jarl.no` domain,
outside this row's six markers and so untouched here.
