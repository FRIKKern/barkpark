# studio-flake-census

Which `Phoenix.LiveViewTest` sites read the store before the LiveView has
processed the self-message that writes it.

    python3 tooling/studio-flake-census/census.py           # -> RESULT-v2.json
    python3 tooling/studio-flake-census/census_selftest.py  # 13 controls, exit 1 on any red

**This is a LEAD GENERATOR, not a verdict.** v1 produced exactly two leads and
measurement refuted both. Nothing here should be built on until it has been
measured with an ablation (remove the barrier, run `--repeat-until-failure`,
and keep a positive control on the same box under the same load).

## The rule

A **barrier** is anything issuing a *second, later* `GenServer.call` to the
LiveView pid. `Phoenix.LiveViewTest.render/1` and every `render_*` helper
resolve to `Phoenix.LiveView.Channel.ping/1`, i.e. `GenServer.call(pid,
{:phoenix, :ping}, :infinity)`. `:sys.get_state/1`, `:erlang.process_info/2`
and `Process.info/2` call the same pid. `assert_receive`, `render_async` and
`Process.sleep` order by other means but order all the same. A helper whose
body transitively contains one IS one — whether it is defined in the test file
or imported from `api/test/support/`.

Position matters. A call in **argument position** of the enqueueing
expression — `"if_rev" => paper_rev(view)` inside `render_hook(target,
"inner-flush", %{...})` — is evaluated *before* the message is sent and is not
a barrier for it. A tail `render(view)` on the next line is. The scan starts
where the trigger's call expression **closes**, not at its first line.

Two windows, not one:

    W1  inside the TRIGGER HELPER, from the close of its last enqueueing
        expression to the end of the helper          <- the rung v1 lacked
    W2  in the test block, from the close of the trigger expression to the
        assertion line

**How many barriers are enough is decided by the chain's HOP COUNT, not by the
site.** One barrier is one ping; it orders only against messages already in the
mailbox when it arrives.

- A **1-hop** chain sends its message from inside the `GenServer.call` the
  trigger is already blocking on, so it is in the mailbox before the next ping:
  one barrier drains it deterministically.
- A chain of **2+ hops** enqueues hop N+1 while handling hop N — after the ping
  has been answered. No fixed number of barriers is sound. Only a settle loop
  (ping until `:erlang.process_info(pid, :message_queue_len)` reads 0, twice)
  is. `BarkparkWeb.LiveSettle.settle!/2` is that loop; the census finds it by
  **shape**, never by name.

| verdict | meaning |
|---|---|
| `MASKED-BY-BARRIER` | 1-hop, ≥1 barrier in W1 or W2. Safe today. |
| `RACING-ONE-HOP` | 1-hop, zero barriers. Needs one barrier. |
| `RACING-MULTI-HOP` | ≥2 hops without a settle loop. **The hazard class** — a single barrier does not save it. |
| `SETTLED-MULTI-HOP` | ≥2 hops with a settle loop in the window. |

## The chains

Hop counts are derived in `chains.json`, which cites every enqueue site.
`census_selftest.py` case C6 reds if a cited site stops enqueueing.

| chain | hops | the hops |
|---|---|---|
| `CH-PAPEROP` | 1 | `paper_field_block.ex:350/352` `send(self(), {:paper_op, …})` |
| `CH-AUTOSAVE` | 1 | `handlers/refs.ex:42,49` + `handlers/media.ex:59,66,93` `send(self(), {:autosave_form, …})` |
| `CH-CHAT` | 1 | `chat_live.ex:554` `send(self(), {:dispatch_send, …})` |
| `CH-TREE` | 3 | `tree_codelist_field.ex:179` `send(self(), {:tree_codelist_change, …})` → `handlers/lifecycle.ex:316` `send_update/3`, which is `send(self(), {:phoenix, :send_update, …})` → `paper_field_block.ex:350/352` `send(self(), {:paper_op, …})` |

## What v1 got wrong

v1 lives in the campaign scratchpad at `studio-s29-a1/`. Its `RESULT.json` is
**superseded**; both of its two leads were measured and refuted (PR #19712 /
task-97bb0fb9c044192f, PR #19724 / task-0ef0c4a72fa28035). Two defects, both
in the barrier rung:

- **D1 — `render/1` was not in the barrier vocabulary at all.** v1's pattern
  was `:sys\.get_state\(|assert_receive|render_async|Process\.sleep|
  GenServer\.call|…`. It matches `render_async(` and does *not* match
  `render(` or `render_hook(`. A plain `render(view)` between the trigger and
  the read — the single most common barrier in this tree — was invisible.
  Control: `census_selftest.py` C1a/C1b.
- **D2 — the barrier scan started after the trigger's CALL SITE.** v1 resolved
  file-local helpers transitively when hunting the trigger and the read, but
  judged "is there a barrier between them" over the test block's own
  statements. The tail `render(view)` at the end of `inner_change/2` was never
  looked at. Control: C2a/C2b.

Two further corrections v1's own correction note did not make:

- **Chain attribution must be per TRIGGER, not per test block.**
  `slash_menu_and_codelist_test.exs:256` clicks `tree_node_select` *and* calls
  `flush_form/3`; a block-level union hands the 3-hop CH-TREE label to the
  1-hop CH-PAPEROP trigger's window and measures the wrong gap.
- **v1's own headline counts were wrong about itself.** Its `RESULT.json`
  holds 30 `RACING` / 29 `MASKED`, not the "2 RACING / 24 MASKED-BY-DUPLICATE
  / 31 MASKED-BY-BARRIER / 2 CLEAR" reported downstream.

## Current population

1921 test files scanned (the fence is a rule — every `.exs` under `api/test` —
not a hand-list; v1's 301-file fence was a snapshot). 68 sites in 13 files.

    by hop count   1-hop: 64      3-hop (CH-TREE): 4
    by verdict     MASKED-BY-BARRIER 58 | RACING-ONE-HOP 6
                   RACING-MULTI-HOP 1  | SETTLED-MULTI-HOP 3
    by chain       CH-CHAT 37 | CH-PAPEROP 27 | CH-TREE 4 | CH-AUTOSAVE 0

`CH-AUTOSAVE` is zero: no test drives `select-media` / `clear-image` /
`upload-image` / `select-ref` / `clear-ref` and then reads the store under an
assertion. That is an absence with a control — the same trigger vocabulary
finds 27 CH-PAPEROP and 37 CH-CHAT sites in the same pass.

### Leads, ranked. UNMEASURED.

| site (block → trigger) | chain | hops | verdict | barriers |
|---|---|---|---|---|
| `paper_editor/slash_menu_and_codelist_test.exs:256` → L282 | CH-TREE | 3 | `RACING-MULTI-HOP` | 3 |
| `chat_live_test.exs:2684` → L2686 | CH-CHAT | 1 | `RACING-ONE-HOP` | 0 |
| `chat_live_test.exs:2779` → L2784 | CH-CHAT | 1 | `RACING-ONE-HOP` | 0 |
| `chat_live_test.exs:6673` → L6675 | CH-CHAT | 1 | `RACING-ONE-HOP` | 0 |
| `chat_live_test.exs:7512` → L7530 | CH-CHAT | 1 | `RACING-ONE-HOP` | 0 |
| `chat_live_test.exs:8388` → L8392 | CH-CHAT | 1 | `RACING-ONE-HOP` | 0 |
| `paper_editor/slash_menu_and_codelist_test.exs:256` → L288 | CH-PAPEROP | 1 | `RACING-ONE-HOP` | 0 |

The first row is the only one on a multi-hop chain and is the only site in the
tree where barriers are present and still insufficient. The six 1-hop rows need
one barrier each, which is a one-line change per site — but *measure first*:
that is exactly the reasoning that produced v1's two refuted leads.

## Controls

`census_selftest.py` is 13 cases. Every predicate case is a **matched pair** —
a fixture and its minimal mutation — because a case that only asserts the
expected verdict passes for a predicate that answers that verdict always.

- C1a/b, C2a/b, C3a/b, C4a/b — the pairs for D1, D2, argument position, hop count
- C5 — determinism over two full runs. This was RED: `calls_of` memoised on
  `id(txt)`, per-file dicts are garbage-collected, CPython reuses the address,
  and two runs over an unchanged tree printed 58/6 then 53/11.
- C6 — every enqueue site `chains.json` cites still enqueues
- C7a/b — the two refuted sites, pinned by outcome
- C8 — **no special-casing**: no fixture file or helper name appears in
  `census.py`'s decision path (comments excepted), with a control proving the
  scan can find a name that *is* there. An enumeration is a snapshot; a
  predicate is a rule.

C7b reports 24/25. The 25th is `slash_menu_and_codelist_test.exs:256`'s
CH-PAPEROP trigger, whose block's hazard is the CH-TREE chain reported on its
own row — not a family miss.
