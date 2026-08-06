# E06 — versioned canonical projection

This isolated Diverge candidate preserves the four baseline-sealed raw Paper captures byte-for-byte and derives `barkpark.paper.canonical-projection/v1`. It does not modify production data, a Paper, Cycle authority, campaign ledgers, or another candidate.

The projection declares separate document, document-revision, release, projection, cache, and Cycle identities; strong source and projection validators; source provenance; NFC-only authored normalization; and adapters for public HTML, read-only Studio JSON, width-80 TUI text, RFC MIME email, and CLI/API JSON/text. Headerless tables remain headerless. Conflicting `header`/`head` aliases are quarantined rather than guessed.

Reproduce from this directory:

```sh
python3 scripts/build.py
python3 scripts/replay.py
python3 scripts/verify.py
python3 scripts/finalize.py
```

`generated/source/` contains immutable source copies; `generated/projections/` contains the versioned projections; `generated/adapters/` contains reader artifacts; and `generated/receipts/` contains reader, quarantine, and rollback receipts. `evidence.tar.gz` is a deterministic archive of the full generated candidate.

Observed: local schema/preservation/identity/validator/adapter/replay/recovery checks pass. Authenticated Studio, real browser and assistive-technology captures, interactive installed TUI, delivered mail clients, and a live deployed CLI/API endpoint remain `BLOCKED`, never proxy-passed. Preference (not observation): explicit projection versioning makes identity and cache provenance legible, but adds version-negotiation and lifecycle cost that Attack must compare against the other architectures.
