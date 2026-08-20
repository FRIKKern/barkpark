# Re-derivation: the crown oracle for `mob-w3-rich-tail` criterion 9 (stable-frame capture)

Measured 2026-07-28 against `origin/main` @ ab396959c (worktree = the main checkout, clean).

## Q1 — what terminal reason does an INTERRUPTED turn emit?

`degraded` is emitted ONLY when the turn's accumulator is still live at a turn
boundary or on a converter fault. An interrupt whose partial text still arrives
as a provider `assistant` frame settles NORMALLY (`settled`).

```sh
git show origin/main:api/lib/barkpark/studio_chat/recorder.ex | grep -n 'stable_settle\|stable_start\|stable_abandon\|reason: "degraded"'
# 514 stable_settle(state, assistant_text(blocks))   <- assistant frame => settle path
# 527 stable_start(state)                            <- "result" frame => abandon => degraded
# 1966-1976 stable_abandon: emits degraded iff phase==:live and emitted_to>0
```

Empirical: the 2026-07-26 D41 drive interrupted turn 2 mid-stream and the
partial text STILL PERSISTED as an assistant row (seq 5, 27 bytes), so the
assistant clause fired:

```sh
python3 - <<'EOF'
import json,re
t=open('tooling/chat-drive/transcript-2026-07-26.txt').read()
b=max((json.loads(s) for s in re.findall(r'<< 200 (\{"id":"32f99668[^\n]*)',t)),key=lambda x:len(x.get('messages',[])))
print([(m['seq'],m['role'],len((m.get('source_markdown') or '').encode())) for m in b['messages']][:5])
EOF
# -> [(1,'user',101),(2,'assistant',415),(3,'user',114),(4,'thinking',24),(5,'assistant',27)]
```

## Q2 — the $2.00 D41 cap is PER-SESSION (in practice per-RUN), not per-wave

`spend_guard()` re-reads the ONE session the run created and tests
`.total_cost_usd` against `$1.50` / `$2.00`. Nothing aggregates across runs.

```sh
grep -n 'SPEND_CAP=\|SPEND_ABORT=\|session_field .total_cost_usd' tooling/chat-drive/drive.sh
grep -o 'sessions/[0-9a-f-]\{36\}' tooling/chat-drive/transcript-2026-07-26.txt | sort -u   # -> ONE id
grep -o 'spend check: total_cost_usd=[0-9.]*' tooling/chat-drive/transcript-2026-07-26.txt
# -> 0.0 / 0.0923307 / 0.1846614 / 0.33107430000000004   (final read 0.5519112)
```

## Q3 — the mechanical oracle: `reason:"settled"` ALONE is vacuous

A boundary is a BLANK LINE outside every fence (`stream_tail.ex` `apply_line/4`,
`line == "" -> %{scan | boundary: nl + 1}`). A turn with no blank line therefore
emits ZERO mid-turn frames and STILL terminates `settled` — the settle path
emits one whole-turn `stable` then the closer.

```sh
cd api && CC=clang MIX_ENV=test mix run --no-start ../tooling/grip/ledger/_oracle_probe.exs
# ONE PARAGRAPH          -> stable 0..130 ; stable_end from=130 settled          (1 frame)
# BLANK-LINE MULTI       -> stable 0..34, 34..75, 75..109, 109..137 ; settled    (4 frames)
# ONE PER LINE, NO BLANKS-> stable 0..310 ; stable_end from=310 settled          (1 frame)
```

(The probe is `tooling/grip/ledger/_oracle_probe.exs`, a ~20-line
`StreamSegments.new/advance/settle` driver; both drive.sh prose turns are
1-frame shapes.)

Therefore the capture must assert, over the raw SSE bytes:

1. `>= 2` `event: stable` frames for one `turn`, each `data:` a JSON object
   carrying exactly the D59 terms `turn, from, to, blocks` (+ `skeleton`, nullable);
2. contiguity: frame[0].from == 0 and frame[i].from == frame[i-1].to for all i;
3. one terminal `event: stable_end` with `{turn, from, reason}` where
   `reason == "settled"` and `from >= last stable.to`;
4. no `id:` line on either frame kind (`sse_stable_frame/1`,
   `api/lib/barkpark_web/controllers/chat_controller.ex:758-762`).

The eliciting prompt MUST demand BLANK-LINE-SEPARATED paragraphs, and must avoid
`[ref]: url` link-reference lines and stray inline backticks — both are named
`degraded` terminators (`stream_segments.ex` `state.linkref` / `count_backtick_runs`).
