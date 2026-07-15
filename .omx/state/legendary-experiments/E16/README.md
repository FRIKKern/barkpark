# E16 — lossless semantic tree preservation candidate

E16 executes the exact assignment in `E11/next-three-assignments.json` against
the 36 frozen E03 fixtures. It does not mutate product code, production data, or
the frozen sources. The candidate encodes each source as a reversible typed tree,
preserving exact Unicode codepoints, hierarchy, key order, sequence order, links,
status cues, and PortableDoc node types.

```bash
python3 .omx/state/legendary-experiments/E16/scripts/build.py
.omx/state/legendary-experiments/E16/scripts/replay.sh
```

The real five-surface materialization/accessibility proof is intentionally
`BLOCKED_E17_SCOPE`. The unsupported-alias idea from E10 is deferred and is not
added to the canonical 36-fixture manifest.
