# Re-derivation recipes — the after-measurement, the cap's verdict, the honest denominator (2026-08-06)

Builder slice `dr-w6-s3-the-proofs-and-the-ledger-repair`, deploy-reliability wave 6.
Every number below carries the exact command that produces it. Nothing here is
quoted from a brief — all of it was re-derived at write time, and where the
re-derived value DISAGREES with the number the wave was briefed on, both are
printed and the disagreement is named rather than reconciled away.

The headline is a REGRESSION. Read Part A §3 before anything else.

---

## Part 0 — the shell, and why `eval` cannot do this

The census is `BarkparkCloud.DeployLedger.census/2`, a FUNCTION, not a query.
It must run inside the started application: `eval` boots a bare VM with no
Repo and dies with

    could not lookup Ecto repo BarkparkCloud.Repo because it was not started

so every reading below is taken through `rpc` against the live control plane.

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      'docker cp /tmp/census.exs cloud-control_plane_blue-1:/tmp/census.exs;
       docker exec cloud-control_plane_blue-1 /app/bin/barkpark_cloud rpc \
         "Code.eval_file(\"/tmp/census.exs\")"'

Node `178.105.92.191`; app container `cloud-control_plane_blue-1`; DB container
`cloud-db-1`, database `barkpark_cloud_prod`.

**The HTTP route is still 403-dark.** `GET /v1/operator/deploy-ledger/census`
is unreachable to every human because `PLATFORM_ADMIN_EMAILS` is unset on prod.
`dr-w2-s8` criterion 7 asks for the source to be the census function rather than
hand-written psql; an operator shell running the shipped function satisfies that
STRICTLY MORE STRONGLY than the route would have — the route is a wrapper over
this exact call. It is named here as owed, not as met.

### The box was quiet, and the reading is not the load

`uptime` on the CP node, printed BEFORE and AFTER the census run:

    18:52:53 up 38 days,  3:54,  1 user,  load average: 0.65, 0.51, 0.40   # before
    18:52:54 up 38 days,  3:54,  1 user,  load average: 0.65, 0.51, 0.40   # after

Re-derive: `ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 uptime` on either
side of the `rpc`. The whole census is sub-second — one grouped query over
~29,000 rows, classified per GROUP.

### The window pins, and why `to` is not `now()`

    BEFORE : 2026-08-05T17:00:00Z .. 2026-08-05T21:24:00Z
    AFTER  : 2026-08-05T21:24:00Z .. 2026-08-06T18:00:00Z

`21:24:00Z` is the wave-1/2 cutover instant. The AFTER `to` is pinned at
`18:00:00Z` and NOT at wall clock (18:52Z at write time) because a row's
terminal status can land up to 37.8 minutes after its `inserted_at`:

    max(updated_at - inserted_at) over the AFTER window = 2269.9 s = 37 min 50 s

Re-derive:

    Repo.one(from d in "deployments",
      where: d.inserted_at >= ^~U[2026-08-05 21:24:00Z],
      select: max(fragment("? - ?", d.updated_at, d.inserted_at)))

A `to` closer than that to the clock reads rows that have not finished settling
and the window mutates under you. 18:00Z is 52 minutes behind — safe.

**The AFTER window is not the one the wave was briefed on.** The brief's pins
produced `volume 1947 / failed 852`; mine produce `volume 2002 / failed 880`,
because the window kept accruing between DECIDE and this write. Every delta
below traces to that and to nothing else.

---

## Part A — the after-measurement, in all three conventions

### A.1 The raw census, both windows

```elixir
alias BarkparkCloud.DeployLedger
DeployLedger.census(~U[2026-08-05 17:00:00Z], ~U[2026-08-05 21:24:00Z])   # BEFORE
DeployLedger.census(~U[2026-08-05 21:24:00Z], ~U[2026-08-06 18:00:00Z])   # AFTER
```

Output, verbatim:

    ===== BEFORE 2026-08-05T17:00:00Z .. 2026-08-05T21:24:00Z
    volume=565 failed=505 failure_rate=%{reason: nil, refused: false, min_sample: 200,
                                         numerator: 505, pct: 89.38, sample: 565}
    min_sample=200
    deferred_total=0
    -- classes (numerator) --
      BOX_BUSY_409 269 share=53.27 refused=false
      DOC_ID_EMPTY 116 share=22.97 refused=false
      BOX_500 49 share=9.7 refused=false
      FORBIDDEN_403 35 share=6.93 refused=false
      BOX_UNAVAILABLE_503 17 share=3.37 refused=false
      BUILD_FAILED 13 share=2.57 refused=false
      PROCESS_DIED 3 share=0.59 refused=false
      BOX_UNREACHABLE 1 share=0.2 refused=false
      DEPLOY_TIMEOUT 1 share=0.2 refused=false
      HEALTH_GATE_FAILED 1 share=0.2 refused=false
      CLASS_SUM=505
    -- deferred --
    -- not_attempted --
    []

    ===== AFTER 2026-08-05T21:24:00Z .. 2026-08-06T18:00:00Z
    volume=2002 failed=880 failure_rate=%{reason: nil, refused: false, min_sample: 200,
                                          numerator: 880, pct: 43.96, sample: 2002}
    min_sample=200
    deferred_total=603
    -- classes (numerator) --
      BOX_500 298 share=33.86 refused=false
      DOC_ID_EMPTY 217 share=24.66 refused=false
      BUILD_FAILED 184 share=20.91 refused=false
      BOX_UNAVAILABLE_503 149 share=16.93 refused=false
      BOX_UNREACHABLE 16 share=1.82 refused=false
      PROCESS_DIED 14 share=1.59 refused=false
      BOX_BUSY_409 1 share=0.11 refused=false
      HEALTH_GATE_FAILED 1 share=0.11 refused=false
      CLASS_SUM=880
    -- deferred --
      BOX_BUSY_DEFERRED 603 share=30.12
    -- not_attempted --
    []

### A.2 The three conventions, side by side

| # | Convention | BEFORE | AFTER | Δ |
|---|---|---|---|---|
| 1 | OLD, both ends — `(failed + deferred) / volume` | 89.38% | 74.08% | −15.30pp |
| 2 | SHIPPED, as the rows were literally written — `failed / volume` | 89.38% | 43.96% | −45.42pp |
| 3 | **SHIPPED, DOCTRINE-MATCHED** — BEFORE's `BOX_BUSY_409` moved into the deferred cohort | **41.77%** | **43.96%** | **+2.19pp** |

Arithmetic, each row:

    (1) BEFORE (505 + 0) / 565   = 89.38   AFTER (880 + 603) / 2002 = 74.08
    (2) BEFORE  505      / 565   = 89.38   AFTER  880       / 2002 = 43.96
    (3) BEFORE (505-269) / 565   = 41.77   AFTER  880       / 2002 = 43.96

Re-derive all six with `Float.round(n * 100 / d, 2)` on the census fields
printed in A.1, or run the derivation block appended to the census script:

    OLD BEFORE (failed+deferred)/vol = 89.38
    OLD AFTER  (failed+deferred)/vol = 74.08
    SHIPPED BEFORE failed/vol = 89.38
    SHIPPED AFTER  failed/vol = 43.96
    BEFORE BOX_BUSY_409=269 busy_share=47.61
    AFTER deferred=603 defer_share=30.12
    DOCTRINE-MATCHED BEFORE (failed-BOX_BUSY_409)/vol = 41.77

### A.3 The headline: row 3, and it is a REGRESSION

**41.77% → 43.96% = +2.19 percentage points WORSE.**

Row 2 is the number that flatters, and it must never be published as repair: it
compares two DIFFERENT conventions. In BEFORE, a busy box's 409 was written as a
`failed` row; in AFTER, wave 1's re-key settles the same event as `deferred` and
it leaves the numerator. Subtracting 269 rows from one side of a comparison and
calling the difference an improvement is arithmetic, not engineering. Row 3 puts
BEFORE on today's convention and asks the only fair question — of the deploys
that actually SETTLED, what share failed — and the answer got slightly worse.

The honest sentence:

- Busy-refusal pressure **fell**: 47.61% → 30.12% of volume (269/565 → 603/2002).
- Settled failures **rose**: 41.77% → 43.96%.
- `BOX_500` per attempt **doubled**: 8.67% → 14.89%.

  Re-derive: `49/565 = 8.67`, `298/2002 = 14.89`. **Doubled, not tripled** —
  the raw count went 49 → 298 (6.1×) but volume went 565 → 2002 (3.5×), and the
  count alone is a volume artefact.

So: the fleet stopped mis-labelling a busy box as a failure, and that is real.
It did not stop failing. It fails slightly more often, and the growth is
concentrated in `BOX_500` and `BUILD_FAILED` — a box under pressure, which is
the epic's own thesis.

### A.4 The 46.41% that could not be reproduced

The wave digest carries a doctrine-matched BEFORE of **46.41%**. Through the
instrument at these pins the derivable value is **41.77%**, and no combination
of the census's own fields produces 46.41 (505/565 = 89.38, 236/565 = 41.77,
269/565 = 47.61). It is not reconciled here and it is not published: an
unreproducible number is dropped, and the discrepancy is reported so the next
reader does not re-derive it a third time and assume they are wrong.

### A.5 Per-site, beside the aggregate, with the refusals PRINTED

`@min_sample 200` — `DeployLedger.rate/2` refuses to state a percentage below
it and says so in the row. Both cohorts, verbatim (`site_id` resolved to slug
via `Repo.all(from s in "sites", select: {type(s.id, :string), s.slug})`):

**BEFORE** — every site refuses; the window is 4h24m and no site reaches 200:

    search-ember     vol=114 failed=111 deferred=0 pct=nil refused=true reason="sample 114 below min_sample 200"
    astro-search     vol=113 failed=111 deferred=0 pct=nil refused=true reason="sample 113 below min_sample 200"
    search           vol=112 failed=110 deferred=0 pct=nil refused=true reason="sample 112 below min_sample 200"
    search-capstone  vol=112 failed=112 deferred=0 pct=nil refused=true reason="sample 112 below min_sample 200"
    live-auto        vol=110 failed= 59 deferred=0 pct=nil refused=true reason="sample 110 below min_sample 200"
    perfect-proof    vol=  4 failed=  2 deferred=0 pct=nil refused=true reason="sample 4 below min_sample 200"

**AFTER** — five sites clear the bar, one refuses:

    astro-search     vol=413 failed=147 deferred=138 pct=35.59 refused=false top=BOX_500
    live-auto        vol=401 failed= 95 deferred= 95 pct=23.69 refused=false top=BOX_500
    search-capstone  vol=398 failed=272 deferred=112 pct=68.34 refused=false top=BUILD_FAILED
    search           vol=386 failed=180 deferred=125 pct=46.63 refused=false top=DOC_ID_EMPTY
    search-ember     vol=385 failed=183 deferred=133 pct=47.53 refused=false top=DOC_ID_EMPTY
    perfect-proof    vol= 19 failed=  3 deferred=  0 pct=nil   refused=true  reason="sample 19 below min_sample 200"

The BEFORE aggregate is stated at 565 and every one of its sites refuses. That
is not a contradiction — it is the instrument doing its job at two altitudes.

### A.6 A zero-attempt site is INVISIBLE, not refused

`site_rows/2` folds over the GROUPS the query returned:

    defp site_rows(groups, site_limit) do
      groups |> Enum.group_by(& &1.site_id) |> Enum.map(fn {site_id, rows} -> …

A site with no rows in the window produces no group, so it never enters the
fold, and it therefore has no `refused: true` row to print. **Demanding a
printed refusal for a zero-attempt site is unsatisfiable.** What can be demanded
— and is printed here — is an explicit ZERO. Seven of the fleet's thirteen sites
attempted nothing in the AFTER window:

    auto-proof                vol=0 failed=0 deferred=0   ABSENT, not refused
    jarl-website              vol=0 failed=0 deferred=0   ABSENT, not refused
    next-capstone             vol=0 failed=0 deferred=0   ABSENT, not refused
    next-proof                vol=0 failed=0 deferred=0   ABSENT, not refused
    nodeproof-20260718-73191  vol=0 failed=0 deferred=0   ABSENT, not refused
    perfect-demo              vol=0 failed=0 deferred=0   ABSENT, not refused
    perfect-demo-2            vol=0 failed=0 deferred=0   ABSENT, not refused

Re-derive (the set difference the census cannot compute for you):

```elixir
slugs   = Repo.all(from s in "sites", select: {type(s.id, :string), s.slug}) |> Map.new()
present = DeployLedger.census(from, to).sites |> Enum.map(& &1.site_id) |> MapSet.new()
slugs |> Enum.reject(fn {id, _} -> MapSet.member?(present, id) end) |> Enum.map(&elem(&1, 1)) |> Enum.sort()
```

13 sites total, 6 present, 7 absent. `map_size(slugs) = 13`.

### A.7 DEFERRED is explicit, and it is inside volume

    deferred_total = 603, entirely BOX_BUSY_DEFERRED, share 30.12% of volume 2002

Deferrals are inside the denominator (they were real attempts against a real
box) and outside the numerator (a box saying "not now" is the fleet working).
`census/2` splits three ways, not two, and reports the deferred cohort on its
own line so the 409 mass wave 1 RELOCATED is visibly relocated rather than
silently deleted.

### A.8 `GITHUB_PUSH_UNBUILDABLE`, reported at zero

    not_attempted = []   →  GITHUB_PUSH_UNBUILDABLE = 0

Zero in both windows. It is printed anyway: D19 takes this class OUT of the
denominator, so a reader must be able to see that the exclusion moved nothing
rather than assume it. Re-derive: `Enum.reduce(c.not_attempted, 0, &(&1.count + &2))`.

### A.9 There is no `OTHER_FAIL` bucket, and the fold is complete

    class_count = 8
    class_sum   = 880
    failed      = 880
    UNCLASSIFIED = 0

Eight classes sum to EXACTLY `failed`. There is no residual bucket anywhere in
the module — `grep -n 'OTHER_FAIL' cloud/lib/barkpark_cloud/deploy_ledger.ex`
returns nothing. `UNCLASSIFIED` is a real member of `@classes` and is reported
at 0 by absence from the histogram; per the module's own D8, it is DESIGNED to
be able to rise, so a 0 here is a claim about this window, not a guarantee.

Re-derive: `Enum.reduce(c.classes, 0, &(&1.count + &2)) == c.failed`.

### A.10 The configuration tombstone: 149 rows, 16.93% of the numerator

Every one of the AFTER window's 149 `BOX_UNAVAILABLE_503` rows carries the same
raw reason:

    the instance refused the deploy (HTTP 503): feature_not_configured —
    site deploys are not enabled on this instance (set BARKPARK_SITE_DEPLOY_APPLY=1)

Spread over ALL FIVE hot sites:

    astro-search     40
    search-ember     31
    search-capstone  31
    search           25
    live-auto        22
    TOTAL           149   = 16.93% of the 880-row failure numerator
                          = 100% of BOX_UNAVAILABLE_503

Re-derive:

```elixir
Repo.all(from d in "deployments",
  where: d.inserted_at >= ^~U[2026-08-05 21:24:00Z] and d.inserted_at < ^~U[2026-08-06 18:00:00Z]
     and d.status == "failed" and like(d.failure_reason, "%feature_not_configured%"),
  group_by: [type(d.site_id, :string)],
  select: {type(d.site_id, :string), count(d.id)})
```

This is the control plane deploying, over and over, at a box that was never
switched on — a configuration tombstone counted as a deploy failure. It is one
environment variable, and it is a sixth of the epic's headline numerator.

**Backlog row already exists — linked, not duplicated:**
`dr-bl-w6-site-deploy-apply-unset-costs-16pct-of-failures`. (The brief's 138 /
16.2% is the same finding at the narrower window; at these pins it is 149 /
16.93%.)

### A.11 Two `dr-w2-s8` criteria are FALSE as written

**Criterion 5 — "search-capstone is 0-live in the AFTER window" is FALSE.**
It has 14 live deploys:

    search-capstone AFTER: [{"failed", 272}, {"deferred", 112}, {"live", 14}]

Re-derive:

```elixir
Repo.all(from d in "deployments", join: s in "sites", on: s.id == d.site_id,
  where: d.inserted_at >= ^from and d.inserted_at < ^to and s.slug == "search-capstone",
  group_by: d.status, select: {d.status, count(d.id)})
```

`dr-w2-s2`'s wedge repair landed and the site self-heals. The criterion pins a
state the fleet has left; it must be re-worded before anyone stamps against it.

**Criterion 7 — "the source is psql" understates what was done.** The source is
the census FUNCTION via an operator shell (Part 0). The HTTP route is 403-dark.
Running the shipped instrument is strictly stronger than the criterion asks for,
and the criterion should say so rather than being stamped against a weaker
reading.

Neither criterion is stamped by this slice. Re-wording a criterion is the lead's
act, and stamping against wording known to be false is exactly the vacuous green
the charter forbids.

---

## Part B — the cap: the structural verdict now, the live refusal DEFERRED

### B.1 The feared masking does not exist

The door is one serialized GenServer critical section
(`api/lib/barkpark/sites/deploy_runner.ex`, `handle_call({:trigger, …})`):

    cond do
      running_slug?(state, req.slug) ->
        {:reply, {:error, :already_running}, state}

      # THE DOOR. This is one serialized GenServer critical section:
      # drop_stale → running_slug? → box_at_capacity? → start_run all run
      # without interleaving, so two concurrent triggers can NEVER both
      # observe a free slot.
      box_at_capacity?(state, req) ->
        {:reply, {:error, :box_at_capacity}, state}

      true -> start_run(state, req)
    end

The fear was that `already_running`, being checked FIRST, would mask the cap.
It cannot, and the reason is in the two predicates' keys:

    defp running_slug?(state, slug) do          # keyed on ONE slug
      cond do
        match?({:ok, %{state: :running}}, Map.fetch(state.runs, slug)) -> true
        match?({:ok, _}, Map.fetch(state.units, slug)) -> unit_running?(state, slug)
        true -> false
      end
    end

    defp building_slugs(state) do               # folds the WHOLE box
      port_slugs = for {slug, %{state: :running, mode: :deploy}} <- state.runs, do: slug
      unit_slugs = for {slug, %{mode: :deploy} = manifest} <- state.units,
                       is_active(manifest.unit_name) in @active_states, do: slug
      Enum.uniq(port_slugs ++ unit_slugs)
    end

with `@build_slot_capacity 1`.

**Precisely:** the two arms' DECIDING sets are disjoint by construction —
`already_running` decides if and only if the requesting slug is itself in
flight, and `box_at_capacity?` is reached only when it is not. The predicates
themselves OVERLAP (a same-slug build is in `building_slugs/1` too), but both
arms REFUSE. No request that the cap would have stopped can reach `start_run/2`
through the `already_running` arm. The only thing the ordering changes is which
LABEL a same-slug refusal carries. That is a labelling question, not a
correctness one, and the masking the wave feared does not exist.

Re-derive: `sed -n '440,470p;581,587p;750,759p' api/lib/barkpark/sites/deploy_runner.ex`
and `grep -n '@build_slot_capacity' api/lib/barkpark/sites/deploy_runner.ex`.

### B.2 Neither upstream lock preempts it

**The unique index is same-site only.** `deployments_active_site_env_index` is a
UNIQUE PARTIAL index on `(site_id, environment)` —
`cloud/priv/repo/migrations/20260805190000_rekey_active_deployment_index_on_environment.exs`,
surfaced as a changeset constraint in `cloud/lib/barkpark_cloud/registry/deployment.ex`:

    |> unique_constraint(:git_ref,
      name: :deployments_active_site_env_index,
      message: "a build for this site is already in progress")

"for this site" — it says so itself. Two DIFFERENT sites building at once is
exactly what it permits, and exactly what the cap exists to stop.

**Oban serializes JOBS, not builds.** `cloud/config/config.exs` sets
`site_deploy: 1`, and `cloud/lib/barkpark_cloud/sites/template_freshness_worker.ex`'s
own moduledoc says why that is not a build cap, verbatim (lines 59–66):

    The `:site_deploy` queue's concurrency 1 serializes JOBS, not builds:
    `AutoDeployWorker` starts one build per job, so for it the queue really is a
    serial gate — but this worker visits the whole fleet in ONE job, and
    `Deploy.start/1` hands each site to a supervised Task immediately. The box
    single-flights per SLUG only, so after any instance roll … an uncapped sweep
    would start K concurrent builds on a 2-core box that is also serving the
    content API.

Re-derive: `sed -n '55,67p' cloud/lib/barkpark_cloud/sites/template_freshness_worker.ex`
and `sed -n '218,228p' cloud/config/config.exs`.

### B.3 Exposure — a BOUND FROM ABOVE, not a predicted refusal count

    with_foreign | non_deferred | pct
    -------------+--------------+------
           11005 |        11256 | 97.8

97.8% of non-deferred deployments in the trailing 7 days had a FOREIGN-site
deployment row within ±60 s. Re-derive:

```sql
select count(*) filter (where has_foreign) as with_foreign, count(*) as non_deferred,
       round(100.0*count(*) filter (where has_foreign)/count(*),1) as pct
from (select d.id, exists (
        select 1 from deployments e
        where e.site_id <> d.site_id and e.status <> 'deferred'
          and e.inserted_at between d.inserted_at - interval '60 seconds'
                               and d.inserted_at + interval '60 seconds') as has_foreign
      from deployments d
      where d.status <> 'deferred' and d.inserted_at >= now() - interval '7 days') t;
```

**LABEL THIS HONESTLY.** `deployments` has no build start/end pair — only
`inserted_at`. This is an INSERTION-PROXIMITY PROXY, so it is an upper bound on
how often the cap COULD fire, never a prediction of how often it WILL. Two rows
inserted 3 s apart may represent builds that never overlapped. The number says
"the opportunity is pervasive", nothing more.

The brief carried 80.7% (9,189 / 11,384) at an earlier pin; mine is 97.8% at a
trailing-7-day pin taken at write time. Both are bounds from above, both are
`now()`-relative, and a `now()`-relative window is not comparable across runs —
which is itself an argument for pinning it before anyone quotes it again.

### B.4 The retry pipe is alive at volume on its sibling path

603 deferrals in the AFTER window; 661 across the trailing 2 days, and every
deferring site reached `live` inside the same window:

    slug             deferrals   live_since
    astro-search           146          134
    search-ember           142           72
    search                 141           83
    search-capstone        129           15
    live-auto              103          270

Re-derive:

```sql
select s.slug, count(*) filter (where d.status='deferred') deferrals,
       count(*) filter (where d.status='live') live_since
from deployments d join sites s on s.id=d.site_id
where d.inserted_at >= now() - interval '2 days'
group by s.slug order by 2 desc;
```

A deferral is not a dead end on the path the cap will share.

### B.5 The LIVE refusal is DEFERRED — the cap has not SHIPPED

Re-derived at write time on guerrilla (`157.180.90.121`, `/opt/barkpark`):

    $ git rev-parse --short HEAD
    33bb65496
    $ git merge-base --is-ancestor ef77af274 HEAD && echo CAP_PRESENT || echo CAP_ABSENT
    CAP_ABSENT
    fatal: Not a valid object name ef77af274
    $ grep -c box_at_capacity api/lib/barkpark/sites/deploy_runner.ex
    0

The cap commit is not merely un-merged into that checkout — the object is not
present at all, and the box's own `deploy_runner.ex` contains the string zero
times. And in the production ledger:

    select count(*) from deployments where failure_reason like '%box_at_capacity%';
     count
    -------
         0

**Zero `box_at_capacity` rows have ever existed.** Read that correctly: it is
evidence the cap has NOT SHIPPED to the box that does the building, NOT evidence
that it is broken. A predicate that is not on the box cannot refuse, and an
absent refusal from absent code is not a failed proof — it is a proof that has
not been ATTEMPTED. The live proof is deferred with exactly one unblock
condition: `merge-base --is-ancestor` returning CAP_PRESENT on guerrilla.

(The cap merged to `main` as `ef77af274` — `git log --oneline -1` in a
main-derived worktree shows it — so what is owed is the box's pull, not another
merge.)

### B.6 A warning to whoever measures next

Merging the cap steps the deferral rate **by design**: refusals that today
become `BOX_500` or a queued build will become `box_at_capacity` deferrals, and
deferrals sit inside volume and outside the numerator. A failure-rate
measurement taken ACROSS that boundary will show an improvement that is a
convention change, which is the exact error Part A §3 exists to prevent —
committed twice in one epic would be inexcusable. **Stratify by `DeployLedger`
class, or pin the window entirely on one side of the merge.**

---

## Part C — the ledger repair

All of Part C is bp-side. The commands were run; the read-backs are the receipts.

### C.1 `dr-w3-s7-strained-reaches-triage` retired as superseded

    bp task stage dr-w3-s7-strained-reaches-triage open \
      --disposition closed --worker epic-builder-… \
      --note "SUPERSEDED by dr-w5-s1-ladder-reaches-triage …" \
      --rerun "git grep -n ladder_reaches_triage origin/main -- cloud/lib" --yes

Read-back (`bp task get dr-w3-s7-strained-reaches-triage`):

    lifecycle open  disposition closed
    reason: SUPERSEDED by dr-w5-s1-ladder-reaches-triage (11/12, merge-gated only).
            Its own description opens 'THIS SLICE DOES NOT BUILD THIS RUN' and its
            files list is a strict superset of dr-w5-s1's seven. …
    rerun: git grep -n ladder_reaches_triage origin/main -- cloud/lib

`lifecycle` stays `open` deliberately: `bp task stage` reaches `done` for nobody
(`done` is `bp task close` only), and `--disposition closed` is the durable
adjudication term. `dr-w5-s1` stands at 11/12, merge-gated in PR #9887.

### C.2 The drafts phantom discarded — AFTER proving it is a strict subset

Proven BEFORE the discard, not asserted:

    criteria text identical: True
    draft met set {2, 3}   twin met set {0, 1, 2, 3}
    idx 2  draft 461 bytes sha256:52fd3aa471e7dafb | twin 461 bytes sha256:52fd3aa471e7dafb  IDENTICAL
    idx 3  draft 1108 bytes sha256:8b991c97fac958d6 | twin 1108 bytes sha256:8b991c97fac958d6 IDENTICAL

`{2,3} ⊂ {0,1,2,3}` and the two shared evidences are byte-identical, so
copy-before-discard is a provable no-op — there is nothing on the phantom that
is not already on the published twin.

Re-derive (note the addressing trap: `bp doc get task drafts.<id>` returns
`not_found` for a draft that EXISTS; only `bp task get` resolves it):

    bp task get drafts.dr-w5-s4-agent-binary-reaches-the-fleet
    bp task get dr-w5-s4-agent-binary-reaches-the-fleet

Discarded with `bp doc discard-draft task drafts.dr-w5-s4-agent-binary-reaches-the-fleet --yes`
(`rev: 89a4b803ce5ae9a44c51369f86a831b3`). Read-back:

    {"error":{"code":"not_found",…,"message":"not found: task not found"},"ok":false}

and the parent rail's pre-wave-6 open count fell 86 → 85, which is the same fact
seen from the denominator's side.

**The generator is still live.** Within this same run a NEW phantom appeared on
the same rail: `drafts.dr-w6-s2-stale-binary-says-so`, `in_progress`, inserted
`2026-08-06T19:01:35Z`. Discarding them one at a time is mopping; filed as
`dr-bl-w6-phantom-draft-twins-accumulate-on-the-rail`. Re-derive:

    bp task get task-fb4fb869490b4213 -o json | jq '[.children[]|select(.doc_id|startswith("drafts."))]'

### C.3 Two already-satisfied criteria stamped

Both were satisfied in their MERGED PR bodies and merely unstamped. A merged PR
body is editable, so the timeline was checked FIRST in both cases — neither
carries an `edited` or `renamed` event, and in both cases `updated_at` is within
2 s of `merged_at`, so the text predates the merge.

| Task | idx | PR | Body line | Timeline events | updated_at vs merged_at |
|---|---|---|---|---|---|
| `dr-w2-s4-scrub-knows-our-own-token` | 5 | #9731 | 3 | closed, committed ×2, cross-referenced ×3, head_ref_deleted, merged | +2 s |
| `dr-w2-s6-engine-one-extractor-health-slow-vs-broken` | 3 | #9733 | 7 | closed, committed, cross-referenced ×2, merged | +1 s |

Re-derive:

    gh pr view 9731 --json body -q .body | sed -n 3p
    gh pr view 9733 --json body -q .body | sed -n 7p
    gh api repos/FRIKKern/barkpark/issues/9731/timeline --paginate -q '.[].event'
    gh api repos/FRIKKern/barkpark/issues/9733/timeline --paginate -q '.[].event'
    gh api repos/FRIKKern/barkpark/pulls/9731 -q '.updated_at+" / "+.merged_at'

Read-backs: `dr-w2-s4` 6/8 → **7/8**, `dr-w2-s6` 6/9 → **7/9**, both returned to
`lifecycle: open` (a stamp requires holding the claim, so each row was claimed,
stamped, and staged straight back to `open`; neither was closed — both remain
merge-gated for the LEAD).

**One honest wording note on `dr-w2-s4` idx 5.** The criterion says the body
"flags this as HIGH-FLIP-RISK". #9731's body does not contain that literal
token; it flags the risk as `⚠ SECRET-BOUNDARY JUDGMENT` and "both failure
directions are silent", and it DOES explicitly request the independent second
reviewer as a manual lead step, naming charter D35. Stamped on substance, with
that divergence written into the evidence rather than papered over.

### C.4 Three criteria are genuinely DEAD — recorded, NOT stamped

These are for the LEAD to retire. Retro-editing a merged body to turn one green
would be precisely the vacuous pass this charter forbids.

| Task | idx | Criterion (abridged) | Why dead |
|---|---|---|---|
| `dr-w2-s6-engine-one-extractor-health-slow-vs-broken` | 6 | body states dr-w2-s2 and this slice are "two halves of one repair" | ZERO hits for `two halves` or `dr-w2-s2` in #9733's 18-line body |
| `dr-w2-s1-recorder-build-id-keyed-log` | 6 | OOM-killed unit; whether the tee'd FILE retained its final lines | dead BY SUCCESSION — #9727 body line 20 records the honest `--miss` and files `dr-w2-s1-followup-oom-tee-flush` |
| `dr-w1-s5-swallow-records-upstream-status` | 7 | three advisory template workflows named and pasted green | ZERO hits for `search-starter-smoke` / `astro-finder-drift` / `astro-search-finder-test` in #9617's 31-line body |

Re-derive:

    gh pr view 9733 --json body -q .body | grep -ciE 'two halves|dr-w2-s2'          # 0
    gh pr view 9617 --json body -q .body | grep -ciE 'search-starter-smoke|astro-finder-drift|astro-search-finder-test'   # 0
    gh pr view 9727 --json body -q .body | sed -n 20p

#9727 line 20, verbatim:

    **Lead must know:** criteria 6 and 9 stay open on the task — one is
    merge-gated, one is the OOM/tee probe the builder honestly stamped `--miss`
    (filed as `dr-w2-s1-followup-oom-tee-flush`).

### C.5 The honest denominator: 71

Re-derived from the PARENT RAIL. **`_id` filters and `bp search` are silently
vacuous here.** Run at write time against a document that demonstrably exists
and is published (`dr-w2-s4-scrub-knows-our-own-token`, read back at 7/8 in C.3
minutes earlier):

    $ bp doc query task --filter '_id*=dr-w2-s4'
    {"count":0,"documents":[],"limit":100,"offset":0,"perspective":"published"}

A confident `count: 0` for an extant published row. Any denominator taken that
way reads clean and is wrong. The only trustworthy read is the rail itself:

    bp task get task-fb4fb869490b4213 -o json | jq '.children | group_by(.lifecycle_status) | map({(.[0].lifecycle_status): length}) | add'

Wave 6 filed 11 rows of its own between 18:25Z and 18:33Z (5 slices + 6 `dr-bl-w6-*`
backlog rows), so the pre-wave-6 rail — the population the denominator is about —
is isolated by `inserted_at < 2026-08-06T18:25:00Z`:

    pre-wave-6 children 97  =  85 open + 11 done + 1 cancelled

That is 98 before this slice's repair; the phantom discard in C.2 removed
exactly one open row (86 → 85). The arithmetic:

    85 open
     − 13  stale-open rows whose OWN build PR is MERGED (see below)
     −  1  dr-w3-s7-strained-reaches-triage, retired in C.1
    ─────
      71   the honest open-work denominator

    71
     −  4  BUILT and sitting in OPEN PRs #9887 #9888 #9889 #9890
    ─────
      67   unbuilt

The 13 stale-open-with-merged-PR rows, re-derived by matching each open
`dr-w*` doc_id against the bodies of the last 200 merged PRs:

    dr-w1-s1-graph-visibility-bound-readmit                 #9613
    dr-w1-s2-fleet-ledger-classifier                        #9614
    dr-w1-s3-409-deferral-index-rekey                       #9615
    dr-w1-s4-webhook-doctype-filter                         #9616
    dr-w1-s5-swallow-records-upstream-status                #9617
    dr-w2-s1-recorder-build-id-keyed-log                    #9727
    dr-w2-s2-provision-rmrf-wedge                           #9729
    dr-w2-s3-poll-grace-5xx-and-named-refusal               #9730
    dr-w2-s4-scrub-knows-our-own-token                      #9731
    dr-w2-s5-cli-status-stops-lying                         #9732
    dr-w2-s6-engine-one-extractor-health-slow-vs-broken     #9733
    dr-w2-s7-scoped-search-permission-clamp                 #9734
    dr-w3-s5-door-refuses-box-at-capacity                   #9827

Re-derive:

```sh
gh pr list --state merged --limit 200 --json number,title,mergedAt,body > merged.json
# then, for each open dr-w* doc_id from the rail, grep merged.json bodies+titles for it
```

Follow-up rows (`dr-w1-s4-followup-*`, `dr-w2-s5-followup-*`, …) also match a
merged PR because that PR FILED them; they are excluded — they were filed by the
merge, not built by it. Only a slice's OWN build PR counts.

The four built-and-open:

    #9887 OPEN  feat(cli): bp cloud status reaches triage — the eleven-rung ladder consumes the box's vitals   (dr-w5-s1)
    #9888 OPEN  feat(agent): the beat carries load15 and the instance's own 5xx rate                            (dr-w5-s2)
    #9889 OPEN  feat(cloud): land the agent's space payload and stop space rows shortening the metrics window   (dr-w5-s3)
    #9890 OPEN  fix(deploy): rebuild barkpark-agent on both self-update lanes                                   (dr-w5-s4)

Re-derive: `gh pr view 9887 --json number,state,title` (and 9888–9890).

**The 13 stale-open rows are NOT closed by this slice.** Those are the LEAD's
closes, on merge, with the epoch machinery that belongs to them.

---

## What this slice did NOT do

- Did not re-word `dr-w2-s8`'s criteria 5 and 7. They are named FALSE AS WRITTEN
  in A.11 with the re-derivation; re-wording a criterion is the lead's act.
- Did not stamp anything on `dr-w2-s8`. Its two broken criteria have to be fixed
  before a stamp against them means anything.
- Did not close the 13 merge-gated rows, and did not close `dr-w2-s4` or
  `dr-w2-s6` after stamping them.
- Did not force a live `box_at_capacity` refusal. It is not possible today: the
  code is not on the box (B.5).
- Did not reconcile the digest's 46.41% (A.4). It is dropped, and the
  disagreement is on the record.
