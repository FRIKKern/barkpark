<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-05 | budget: 1800tok -->
# Restart Verify 05 — email authored-text preservation

Assignment `restart-verify-05` tested ordered survival of every authored heading, paragraph, list item, callout, and table cell in fresh HTTP email previews. Verdict: **refuted**.

All four source endpoints returned `200`, reproduced the frozen revisions, and matched 815/815 source blocks. The canonicalizer emitted one nonempty visible unit per semantic text-bearing node in source order, joined inline mark-split runs, decoded HTML entities, normalized Unicode NFC, and collapsed whitespace without changing case, punctuation, or authored characters. Script/style content was excluded from the preview body.

Email preserves 2,057/2,068 ordered units across 285,715 normalized authored characters. CCH28 passes 667/667, PDS44 369/369, and PDS45 526/526. CCH29 passes 495/506 and loses all eleven paragraph-wrapped nested-list items: 0/11, 406 words, 2,268 characters. No surviving unit was reordered, and no other measured text-unit loss occurred.

| Paper | Revision/blocks | Ordered survival | Email SHA-256 |
|---|---|---:|---|
| CCH28 | `49c1534d…` / 237 | 667/667 | `cfe862c4…` |
| CCH29 | `18768b0a…` / 252 | 495/506 | `dc57c4d6…` |
| PDS44 | `8bbd5d87…` / 99 | 369/369 | `c46f46e5…` |
| PDS45 | `b992fd8a…` / 227 | 526/526 | `3e29bd38…` |

The live failure has a precise shared-renderer explanation. The email controller feeds source blocks to the portable renderer. Its list composer calls `normalize_list_item`, which handles a paragraph map but leaves a list containing one paragraph map unchanged. The inline renderer then treats the nested paragraph as unknown and degrades its `content` to an empty string. This is the same eleven-item loss independently observed in public Verify 04.

This assignment covers HTTP preview, not MIME delivery, SMTP/provider behavior, or Gmail/Outlook/Apple Mail. Text survival also does not prove mark, table, callout, accessibility, or responsive semantics. The repair needs a regression fixture for array-wrapped paragraph list items in the shared renderer and evidence from both public and email paths.

## Cycle payload

```json
{"assignment_id":"restart-verify-05","cycle_assignment_id":"70bb38d9-8fc3-467c-b576-d2f5b0efc856","verdict":"refuted","claim":"email preview preserves every authored fragment, list, table, and callout text in order","canonicalization":"semantic visible units; NFC/entity decode/whitespace collapse; BODY only; case and punctuation unchanged","source":{"papers_exact":"4/4","blocks_exact":"815/815","units":2068,"characters":285715},"email":{"http_200":"4/4","ordered_survival":"2057/2068","papers_passed":"3/4"},"cch29":{"revision":"18768b0a14c2eead927181c4a0e37c18","manifest_sha256":"7396a50a0e9177ed25ba1b0e41e9f064ee7e9b0dc5bc53cb5a6be16a094a86a6","email_sha256":"dc57c4d6704a97ba7003a06694f126c25f9de3f5c8e64529aa20351a3b36e331","nested_items_survived":"0/11","nested_words":406,"missing_characters":2268},"negative_findings":["no other measured text-unit loss","no surviving-unit reorder"],"residual_risk":["HTTP preview is not delivered MIME","mark/table/callout semantics and real clients untested"],"mutations":0}
```
