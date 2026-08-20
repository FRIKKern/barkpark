# Re-derivation recipes — ENOSPC harness fault + wave-66 Paper/heartbeat obligations (2026-08-10)

Written by the wave-66 verify phase (`harness-disk-and-paper`). Every row below is a command that
re-derives a fact this wave quotes. Nothing here is a conclusion; the conclusions live in the wave
Paper `cloud-console-hardening-wave-66-2026-08-10` and in `task-80d117829feec84e`.

## 1. The harness fault, and why the briefed remedy is a no-op

```bash
# The fault itself: at ENOSPC every Bash call dies opening its OWN output file.
df -h /private/tmp | tail -1          # measured before: 228Gi total, 117Mi free, 100% used

# The briefed remedy, proved to match nothing (this is the finding).
ls -1 /private/tmp/claude-501/*/*/tasks/*.output 2>/dev/null | wc -l   # -> 0
rm -rf /private/tmp/claude-501/*/*/tasks/*.output; echo "rc=$?"        # -> rc=1, free unchanged
```

The `*.output` files are the ENOSPC's victim, not its cause: at zero bytes free they cannot be
created at all, which IS the error message. A remedy aimed at the symptom's own victim.

## 2. The actual consumer, and the refill engine

```bash
du -xm -d0 /private/tmp                         # 56 GB before / 45 GB after
du -xm -d1 /private/tmp/claude-501 | sort -rn   # 43.5 GB, of which:
#   33184 MB  .../claude-501/-Volumes-SATECHI-github-barkpark
#   11048 MB  .../claude-501/-Volumes-SATECHI-github-screenscribe   <- the reclaim
S=/private/tmp/claude-501/-Volumes-SATECHI-github-barkpark/47ba8708-cd1d-47ac-93d4-7cb707cf3e3c
du -xm -d2 "$S" | sort -rn | head            # 32.8 GB in ONE session scratchpad
ls -1 "$S/scratchpad" | wc -l                # 3,644 entries, dated 2026-08-07..2026-08-10
git -C /Volumes/SATECHI/github/barkpark worktree list | grep -c claude-501   # 17 REGISTERED
```

Recovery ran only the foreign-project reclaim (`github-screenscribe`): **117Mi -> 11Gi**. The 17
registered worktrees were deliberately NOT swept — one may hold a sibling's unpushed build.

## 3. The du/statfs trap (standing, recurred)

```bash
# Deleting 36 stale session dirs that du valued at ~33 GB freed under 0.5 GB.
df -h /private/tmp | tail -1   # before AND after — size every reclaim by df, never by du
```

APFS counts a clone once per tree for `du` and once in total for the filesystem. `du` is not a
reclaimable-space estimate.

## 4. A working command channel while Bash is dead

The `Monitor` tool runs in the same shell and streams stdout as events rather than through the
failing output file, so it still works at ENOSPC. Redirect to an external volume and read it back:

```bash
O=/Volumes/SATECHI/dev-caches/tmp/w66; mkdir -p $O; <cmd> > $O/out.txt 2>&1; echo done
```

## 5. The publish-quality floor that refuses a wave Paper (and how to pre-check it)

The refusal `invalid_epic_paper_quality` names `details.failures` in its hint and **emits no
`details` key at any verbosity** (`-o json`, `-v`; `-vv` is not a flag). The gate is readable:

```bash
git show origin/main:api/lib/barkpark/content/papers/epic_quality.ex
```

Hard caps that a digest/verify append will hit: `@max_primary_words 5_000`,
`@max_top_level_headings 16`, `@max_top_level_blocks 80`, plus `:table_missing_header`
(the key is `head`, NOT `header`) and `:empty_paragraph_spacer` (this Paper family is authored
WITHOUT Mechanical-Spacing empty blocks — they are a hard FAILURE here).

Collapsed `expandable` blocks (`{"type":"expandable","open":false,"summary":…,"blocks":[…]}`) are
excluded from the primary word count by `first_pass_blocks/1` — that is the sanctioned escape hatch
for a long append, and wave 65's Paper already uses it.

Pre-check locally before writing (a faithful replica of `failures/1`):
`/Volumes/SATECHI/dev-caches/tmp/w66/floor.py`. Validate it against a KNOWN-PASSING paper first —
it reproduced `FAILURES: NONE` on the pre-append wave-66 Paper (3,912 primary words / 40 blocks /
13 headings) and then named both real failures on the naive append (6,951 words / 19 headings).

## 6. The wave-66 obligations, and how to verify each landed

```bash
# Paper: patch -> publish -> INDEPENDENT read-back (a printed `rev` is NOT persistence)
bp doc get paper cloud-console-hardening-wave-66-2026-08-10 -o json \
  | python3 -c "import sys,json;d=json.load(sys.stdin);b=d.get('document',d)['blocks'];print(len(b))"
# -> 49 blocks, _draft False (was 40 before the append)

# Epic heartbeat: wave_status is a FLAT top-level field.
bp doc patch task cloud-console-hardening-epic --set "wave_status=…" --yes
bp doc publish task cloud-console-hardening-epic --yes
bp doc get task cloud-console-hardening-epic -o json      # <- reads it back
bp task get cloud-console-hardening-epic -o json          # <- DROPS it, always None
```

**`bp task get` omits `wave_status` from its projection.** The briefed verification command reads
`None` whether or not a stamp exists, so it cannot distinguish "never stamped" from "stamped and
invisible" — this epic's own sentence, living in the command that checks this epic's heartbeat.
Verify a stamp with `bp doc get task …`, never `bp task get`.

## 7. Filing a row that survives the publish wall

```bash
bp task create "<title>" --description "<non-trivial>" --set parent_id=<epic> \
  --set 'acceptance_criteria:=[…]' --publish --yes
```

Three refusals in sequence, each with a different cause: `label_spine` (needs a non-trivial
description AND 1-12 weighted tags), then tags need a per-entry **`rationale`** with all-distinct
strengths, then every `tags[].tag` must ALREADY be a **registered** `type:tag` document —
minting a new tag name fails the publish. Reuse registered tags (`bp doc ls tag`); the instruments
family uses `honest-gates`, `instrumentation`, `guards-that-can-lose`, `ledger`.

Roster read-back: children carry **`doc_id`**, not `id`/`_id`.

```bash
bp task get cch-instruments-epic -o json | python3 -c \
 "import sys,json;t=json.load(sys.stdin);print(any(c['doc_id']=='task-80d117829feec84e' for c in t['children']))"
```

## 8. Law 0 placement, said out loud in both halves

The ENOSPC row is **urgent for this epic and owned by another**: Law 0 sends every harness, gate and
ledger-hygiene row to `cch-instruments-epic`, filed with `parent_id` AT CREATE TIME (a create, never
a re-parent). Filed there as `task-80d117829feec84e`. Urgency is not ownership.
