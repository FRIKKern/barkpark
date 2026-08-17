# felix-w25 recorder-bounds-settle — re-derivation recipe (2026-08-17)

VERDICT: still-live buildable slice (narrowed). The two-lane contradiction resolves:
runtime_text is TURN-SCOPED (reset per turn), NOT per-session unbounded — but it is
UNBOUNDED WITHIN A TURN, and the durable persist seam has no byte guard. #6537 ("four
numbers", D64=262144) bounded only the DISPLAY emitter (stream_segments tail), never the
durable accumulator or source_markdown persist. Not fenced.

## Re-derive the write/reset cadence
git grep -n 'runtime_text' origin/main -- api/lib/barkpark/studio_chat/recorder.ex
# writes: 1113 (concat, uncapped). resets to "": 341 (init), 1103 (:turn_started),
# 1132 (:turn_completed). persist: 1126/1145 -> persist_runtime_text (1345).
# error/process_failed/protocol_error (1144-1152) persist+settle but do NOT reset (terminal offline).

## Prove #6537 did NOT cap runtime_text (only wired stable_settle)
gh pr view 6537 --json files --jq '.files[].path'   # recorder.ex + stream_segments.ex + test
gh pr diff 6537 | grep -iE 'runtime_text|byte|262144|cap|truncat'
# recorder.ex diff adds stable_settle(state, state.runtime_text) calls only; concat stays uncapped.

## Prove the D64 bound lives on the display emitter, not the persist path
git show origin/main:api/lib/barkpark/studio_chat/stream_segments.ex | grep -n '262_144\|max_stream_display_bytes\|byte_size(tail'
# :113 @default_max_stream_display_bytes 262_144 ; :233 byte_size(tail.text) > max... — the tail accumulator.

## Prove the persist seam is unguarded
git show origin/main:api/lib/barkpark/studio_chat/message.ex | sed -n '30,50p'   # NO validate_length(:source_markdown)
git show origin/main:api/lib/barkpark/studio_chat/recorder.ex | sed -n '1345,1350p' # persist_runtime_text writes text verbatim

## Fence check (not fenced)
for n in $(gh pr list --state open --limit 60 --json number --jq '.[].number'); do gh pr view $n --json files --jq '.files[].path'; done | grep 'studio_chat/recorder.ex'  # empty
git log origin/main -1 --format='%ci' -- api/lib/barkpark/studio_chat/recorder.ex  # 2026-07-28, outside 7-day churn; not a security/console-hardening file
