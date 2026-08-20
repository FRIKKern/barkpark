# Re-derivation recipes — skeleton + fence vocabulary (mobile streaming wave, 2026-07-28)

Verifier lane v12: run `classify_tail`/`stable_boundary` over their trigger corpus and prove the
three derived defects, then size the mobile skeleton work. All Elixir rows run a probe module
built by MECHANICAL extraction of the two private function groups from `origin/main`, so the probe
IS the shipped code (no re-typing):

    git show origin/main:api/lib/barkpark_web/live/studio/chat_live.ex > /tmp/chat_live_main.ex
    { echo 'defmodule TailProbe do'; sed -n '5848,5903p;5905,5923p' /tmp/chat_live_main.ex | sed 's/^  defp /  def /'; echo 'end'; } > /tmp/tail_probe.exs
    cd api && CC=/usr/bin/clang MIX_ENV=dev mix run --no-start <driver>.exs

(`probe_dir`, never `S` — a bare uppercase binding is parsed as an alias and MatchErrors.)

| # | Claim | Command |
|---|---|---|
| 1 | DEFECT 1 (silent): one inline ``` plus a real open fence = EVEN substring count → `{:text, tail}`, so raw fence source streams as prose and NO skeleton appears | probe `classify_tail("Use ``` for fences. Example:\nx\n```elixir\ndef foo do")` → `PROSE_ARM` |
| 2 | DEFECT 1, severe form: one STRAY inline ``` (odd count) pins `stable_boundary` at 0 for the whole turn — 151 of 161 bytes hidden behind a `code` skeleton, nothing ever commits | probe reduce over 5 chunks starting `"You write ``` to open a fence.\n\n"` → `boundary=0` at every step; control without the stray fence commits every chunk |
| 3 | DEFECT 2: the `>` arm passes `""` as prose_before, and the HEEx renders prose only `if String.trim(prose) != ""` → a quote-only tail shows a callout skeleton and ZERO of its 43 bytes | probe `classify_tail("> your log line said 'boom'\nSo the cause is")` → `{:component,"callout",""}`; arms at chat_live.ex:2894-2905 |
| 4 | DEFECT 2 twin: `forming_table?` (`\|`) has the same empty prose_before | probe `classify_tail("\| a \| b \|\n\| --- \|")` → `visible_bytes=0` |
| 5 | DEFECT 3: an unterminated fence skeletons forever — boundary frozen at 18 across 8 growth steps while hidden bytes climb 25→130 | probe reduce over `"Intro paragraph.\n\n```elixir\n"` + `"line N of code\n"` × 8 |
| 6 | EXTRA: `~~~` tilde fences are invisible to the `` ``` ``-only parity law, so the boundary COMMITS mid-code-block and an already-committed block MUTATES at settle (`code("line one")` → `code("line one\n\nline two")`) — append-only violated even AFTER the D75 line-parity migration | probe `stable_boundary("~~~text\nline one\n\nline two\n~~~\n")` = 18 + `FromMarkdown.blocks` on prefix vs whole |
| 7 | EXTRA: the substring counter contradicts its own converter — a mid-line ``` is plain paragraph text and a 4-space-indented ``` is code CONTENT | `FromMarkdown.blocks("Use ``` for fences.\n")` → paragraph; `FromMarkdown.blocks("    ```elixir\n    def foo\n")` → `code("```elixir\ndef foo")` |
| 8 | `FromMarkdown` code blocks carry NO language key → "a code fence gets its chrome and language label" is unreachable on every surface | `FromMarkdown.blocks("```elixir\ndef foo\n```\n")` → `[%{"type"=>"code","value"=>"def foo"}]` |
| 9 | Ordered lists carry no `start` → a mid-list boundary restarts numbering | `FromMarkdown.blocks("1. a\n\n2. b\n")` → `%{"ordered"=>true, "items"=>[…]}`, no `start` |
| 10 | The 7-label vocabulary is exactly diagram/chart/stats/table/callout/code/block, and `code` has NO dedicated skeleton arm — it falls to the generic 3-bar `_ ->` case | `git show origin/main:api/lib/barkpark_web/live/studio/chat_live.ex \| sed -n '3871,3906p;5897,5903p'` |
| 11 | Mobile has ZERO skeleton primitive and ZERO pulse/shimmer token — the only `skeleton` hits are a prose comment in theme.ts; every `pulse` hit is the task-claim pulse | `grep -rni 'skeleton\|pulse\|shimmer' apps/mobile/src/ui/theme.ts apps/mobile/src` |
| 12 | Mobile `Animated` exists in ONE place (a swipe-dismiss PanResponder), never a loop — a pulsing skeleton is net-new animation | `grep -rn 'Animated' apps/mobile/src` |
| 13 | Mobile's `code` renderer is a horizontal ScrollView + `<Text>{str(b.value)}</Text>` — no header, no language label, no copy affordance | `git show origin/main:apps/mobile/src/papers/portabledoc/blocks/core-media.tsx \| sed -n '24,46p'` |
| 14 | The reusable honest-degrade box (dashed border, italic muted label) is `unknownBlock` in registry.tsx | `git show origin/main:apps/mobile/src/papers/portabledoc/registry.tsx \| sed -n '34,60p'` |
| 15 | MermaidIsland re-mints its WebView document on EVERY source change (`useMemo(..., [source, theme])` → `source={{html}}`), so a growing fence is a WebView load per token. Height is `useState(220)` and PERSISTS across source changes — it resets only on remount (key/index shift), so "resets to 220 per token" is FALSE as stated | `git show origin/main:apps/mobile/src/papers/portabledoc/MermaidIsland.tsx \| sed -n '50p;125,155p'` |
| 16 | Zero unit tests on classify_tail/skeleton_label; skeleton coverage is 4 LiveView renders and none of them uses an inline ```, a `>` tail, or a `~~~` fence | `grep -rn 'classify_tail\|skeleton_label\|bp-skel' api/test` → one hit, chat_live_test.exs:937 |
