<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-16 | budget: 1400tok -->
# Restart Survey 16 — CCH29 CLI/API provenance and current pin

Assignment `restart-survey-16` re-attested `cloud-console-hardening-wave-29-2026-08-03::cli_api` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **current Paper pin and renderer body proven; complete human output and restart human projection remain partial**.

## Direct answer

The published Paper is pinned at revision `18768b0a14c2eead927181c4a0e37c18`. Three `paper view -o json` reads, three `doc get` reads, and three narrow source-API reads were stable. The two machine document commands matched at 431,200 bytes and SHA-256 `2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15`. Full-document and narrow-source block arrays match exactly: 252 blocks, 109,740 canonical bytes, SHA-256 `e1cb807591caa511dadb1cc98311812aa364abc624f8da60c24562185b828b21`.

Three installed-binary human renders and one current-worktree render were identical: 126,556 bytes, 1,440 lines, maximum width 80, zero overflow, SHA-256 `e20c839b7be4443eed91bbe148a1f95f1bace8c24eed247fbab0d1c9236fbf83`. The direct pinned renderer body is an exact 1,421-line, 125,535-byte prefix with SHA-256 `043582d797e8547fd3abcf83483ae0e65649913cb3df0eb12fdf782816d8a5c2`.

The final 19 lines and 1,021 bytes are five Related entries from a separate live, fail-open request. They were stable in this short sample but are not bound to the Paper revision. Complete human bytes are therefore not immutable even when the renderer body is.

## Provenance boundary

Machine output exposes ID, revision, title, and all blocks. Human output exposes neither the canonical slug nor revision, so its identity must be established externally. The source response was HTTP 200 JSON with private revalidation caching but no ETag or Last-Modified. History returned 14 events and corroborated the latest publication time, but history entries do not expose revision IDs.

The live Cycle authority matches epic `task-a768c69e659add58`, restart wave `legendary-paper-reader-upgrade-wave-2026-08-06-restart`, wave revision `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`, and inventory digest `227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc`.

## Contradictions and residual scope

The restart wave ID is canonical Cycle authority, not a Paper: published, drafts, and raw Paper reads return `not_found`. The epic task correctly points to the campaign Paper `legendary-paper-reader-upgrade-sweep-2026-08-03`; it does not expose the restart wave ID as a separate `wave_paper`. This is a human-provenance gap, not Cycle corruption. History cannot independently bind its latest event to the exact revision.

Interactive TUI, browser, Studio, email, semantic completeness, and authored quality were outside this CLI/API provenance lens. Related was exercised through CLI output, not captured from its API independently. No mutations ran.

## Cycle payload

```json
{"assignment_id":"restart-survey-16","unit":"cloud-console-hardening-wave-29-2026-08-03::cli_api","paper":{"rev":"18768b0a14c2eead927181c4a0e37c18","blocks":252,"document_sha256":"2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15","source_sha256":"d3bb064cffd3977a6cb466cfa450000f180511b2aac147a1d54c2620c480cfc9","blocks_sha256":"e1cb807591caa511dadb1cc98311812aa364abc624f8da60c24562185b828b21"},"samples":{"paper_json":3,"doc_get":3,"source_api":3,"human_installed":3,"human_current":1},"human":{"lines":1440,"bytes":126556,"sha256":"e20c839b7be4443eed91bbe148a1f95f1bace8c24eed247fbab0d1c9236fbf83","max_width":80,"overflow":0,"body":{"lines":1421,"bytes":125535,"sha256":"043582d797e8547fd3abcf83483ae0e65649913cb3df0eb12fdf782816d8a5c2","equals_direct_renderer":true},"appendix":{"lines":19,"bytes":1021,"entries":5,"sha256":"1d37ea052be0a8db85a23925c4bf2a2c5f3fdf2e8a36759210af6f5cac3228ac","revision_pinned":false},"visible_identity":false},"verdict":"current Paper pin and renderer body proven; complete human output and restart human projection partial"}
```
