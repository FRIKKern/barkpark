<!-- doc-tier: cold | canonical-for: legendary-paper-verify-20-evidence | budget: 1800tok -->
# Verify 20 — platform discovery and Paper reader contracts

Verdict: `proven`. Capabilities, OpenAPI, runtime Paper schema, deployed Paper reads, and CLI discovery describe materially different platform surfaces. The contradiction affects all 20 reader units.

| Surface | Live evidence | Material omission or mismatch |
| --- | --- | --- |
| Capabilities | 200 JSON, 150 commands, SHA `3899d5e9…9815` | no public source, immutable release source, or release render GET |
| OpenAPI | 200 JSON, 151 paths, SHA `098ab833…4ad` | also omits capabilities and OpenAPI themselves |
| Runtime Paper schema | flat/scoped identical, SHA `b4a840f4…437c` | seven metadata fields; no blocks, body, source discriminator, block union, or table vocabulary |
| Four public sources | 200 JSON, 815 blocks | narrow deployed `{id,title,_rev,source}` contract absent from discovery |
| Immutable source | structured 404 for fake candidate | deployed route exists but is undiscoverable |

The four pinned Papers contain 145 headings, 557 paragraphs, 37 lists, 46 tables, and 30 callouts. All headed tables use canonical `header`; runtime schema describes none of this PortableDoc vocabulary.

Content negotiation is internally contradictory: public source with `Accept: */*` returns 200 JSON, while explicit `Accept: application/json` returns a structured 406 `internal_error`. The route is mounted through a browser/public-root pipeline that accepts HTML even though its controller emits JSON. The Go client succeeds because it sends no explicit Accept header.

CLI discovery is partial and separate from machine discovery. Root help exposes only `paper view`; `bp paper help` reveals `capture`; view help reveals six immutable release pins. These built-ins are absent from the capability manifest, so generic consumers cannot discover them.

Live identity was commit `2154e695f`, release `0.2.25`, version `0.2.25.2433`; verifier source was `25caab758e23`. The checked contract files are byte-identical across the divergent histories, so version skew does not explain the mismatches. Conditional ETag reads work for capabilities/OpenAPI, but public source and schema expose neither ETag nor deployment identity.

Focused API-client and CLI tests pass. A successful immutable release read remains unproven because no valid six-pin candidate tuple was discoverable; the deployed 404 proves routing, not success headers. Runtime schema may intentionally cover editable metadata, but no separate machine-readable PortableDoc schema closes the gap.

No repository, Paper, task, or Cycle state was mutated by the verifier. Evidence was collected at clean commit `25caab758e23407e270e7fe0434bd7487de5afb8`.
