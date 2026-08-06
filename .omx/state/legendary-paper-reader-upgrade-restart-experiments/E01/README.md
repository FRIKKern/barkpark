# Restart Experiment E01 — canonical content and structure baseline

This isolated artifact freshly captures the four frozen published Papers through two read-only `bp -s guerrilla` JSON projections while forcing `BARKPARK_MANIFEST=docs/cli/fixtures/full-manifest.json`.

The single canonicalizer has three explicit boundaries:

- `raw`: byte count and SHA-256 only;
- `envelope`: canonical JSON for the complete response object;
- `semantic`: immutable identity, authored metadata, and the ordered block tree, with recursive Unicode NFC as the only text normalization.

The semantic boundary does not trim or collapse whitespace, change case or punctuation, alias `header`/`head`, infer header intent, reorder blocks, or discard unknown block fields. Transport/derived fields excluded from the semantic digest remain present in the envelope artifact.

Run from this directory:

```sh
python3 scripts/build.py
python3 scripts/verify.py
```

The builder invokes only `doc get` and `paper view` reads. It never writes to Barkpark, Task, Paper, Cycle, or production data.
